defmodule NanoAgent.CancelTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Store, Web, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  # A mock that never stops requesting tools, with a small delay per step, so the
  # agent stays alive long enough to be cancelled.
  defp looping_mock do
    Application.put_env(:nano_agent, :mock, fn _m, _t, _o ->
      Process.sleep(80)
      {:ok, Mock.tool_use("t", "bash", %{"command" => "true"})}
    end)
  end

  defp wait_registered(run_id, budget) when budget <= 0, do: false

  defp wait_registered(run_id, budget) do
    case Registry.lookup(NanoAgent.AgentRegistry, run_id) do
      [_ | _] ->
        true

      [] ->
        Process.sleep(20)
        wait_registered(run_id, budget - 20)
    end
  end

  test "cancel stops a running agent and marks it :cancelled" do
    looping_mock()
    {:ok, run_id} = NanoAgent.start_run("a long task")
    assert wait_registered(run_id, 1000)

    assert :ok = NanoAgent.cancel(run_id)
    # process is gone, registry entry cleared
    assert Registry.lookup(NanoAgent.AgentRegistry, run_id) == []
    assert Store.get(run_id).status == :cancelled
  end

  test "cancelling an unknown/finished run returns not_running" do
    assert {:error, :not_running} = NanoAgent.cancel("nope")
  end

  test "cancel works over HTTP" do
    looping_mock()
    start_supervised!({Web, port: 0})
    {:ok, run_id} = NanoAgent.start_run("long")
    assert wait_registered(run_id, 1000)

    url = ~c"http://127.0.0.1:#{Web.port()}/runs/#{run_id}/cancel"

    {:ok, {{_, 200, _}, _h, body}} =
      :httpc.request(:post, {url, [], ~c"application/json", "{}"}, [], body_format: :binary)

    assert :json.decode(body) == %{"ok" => true}
    assert Store.get(run_id).status == :cancelled
  end
end
