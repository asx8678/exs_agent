defmodule NanoAgent.DashboardTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Web, Provider.Mock}

  setup do
    on_exit(fn ->
      Application.delete_env(:nano_agent, :mock)
      Application.put_env(:nano_agent, :approvals, :auto_approve)
      Application.put_env(:nano_agent, :approval_tools, [])
    end)

    start_supervised!({Web, port: 0})
    {:ok, port: Web.port()}
  end

  defp get(base, path) do
    {:ok, {{_, code, _}, _h, body}} =
      :httpc.request(:get, {base ++ String.to_charlist(path), []}, [], body_format: :binary)

    {code, body}
  end

  defp post(base, path, json) do
    {:ok, {{_, code, _}, _h, body}} =
      :httpc.request(
        :post,
        {base ++ String.to_charlist(path), [], ~c"application/json", json},
        [],
        body_format: :binary
      )

    {code, body}
  end

  test "dashboard page renders the fleet UI", %{port: port} do
    {200, html} = get(~c"http://127.0.0.1:#{port}", "/")
    assert html =~ "nano_agent fleet"
    assert html =~ "id=\"grid\""
    assert html =~ "approvals"
  end

  test "pending approvals are listed and can be approved over HTTP", %{port: port} do
    base = ~c"http://127.0.0.1:#{port}"
    Application.put_env(:nano_agent, :approvals, :manual)
    Application.put_env(:nano_agent, :approval_tools, ["write"])
    Application.put_env(:nano_agent, :approval_timeout_ms, 5_000)

    tmp = Path.join(System.tmp_dir!(), "dash_#{System.unique_integer([:positive])}.txt")

    Application.put_env(:nano_agent, :mock, [
      Mock.tool_use("t1", "write", %{"path" => tmp, "content" => "via dashboard"}),
      Mock.end_turn("done")
    ])

    task = Task.async(fn -> NanoAgent.run("write a file", 5_000) end)

    id = wait_for_approval(base, 2_000)
    assert is_binary(id)

    {200, _} = post(base, "/approvals/#{id}", ~s({"decision":"approve"}))

    assert {:ok, r} = Task.await(task, 5_000)
    assert r.status == :ok
    assert File.read!(tmp) == "via dashboard"
    File.rm(tmp)
  end

  defp wait_for_approval(_base, budget) when budget <= 0, do: nil

  defp wait_for_approval(base, budget) do
    {200, body} = get(base, "/api/approvals")

    case :json.decode(body) do
      [%{"id" => id} | _] ->
        id

      _ ->
        Process.sleep(50)
        wait_for_approval(base, budget - 50)
    end
  end
end
