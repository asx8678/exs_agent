defmodule NanoAgent.CascadeTest do
  use ExUnit.Case, async: false

  alias NanoAgent.Provider.Mock

  setup do
    on_exit(fn ->
      Application.delete_env(:nano_agent, :mock)
      Application.put_env(:nano_agent, :subagents_enabled, false)
    end)

    :ok
  end

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: c} when is_binary(c) -> c
      _ -> nil
    end)
  end

  defp agent_count, do: Registry.count(NanoAgent.AgentRegistry)

  defp wait_until(fun, budget) when budget <= 0, do: fun.()

  defp wait_until(fun, budget) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(20)
          wait_until(fun, budget - 20)
        )
  end

  test "cancelling a parent cascades termination to its subagents" do
    Application.put_env(:nano_agent, :subagents_enabled, true)

    # Parent delegates to a child; the child loops forever (stays alive) so we can
    # observe both being terminated by cancelling only the parent.
    mock = fn messages, _tools, _o ->
      text = last_user_text(messages)

      cond do
        String.contains?(text, "CHILD") ->
          Process.sleep(40)
          {:ok, Mock.tool_use("c", "bash", %{"command" => "true"})}

        true ->
          {:ok, Mock.tool_use("s", "spawn_agent", %{"plan" => "CHILD loop forever"})}
      end
    end

    Application.put_env(:nano_agent, :mock, mock)

    before = agent_count()
    {:ok, parent_id} = NanoAgent.start_run("delegate then we cancel")

    # wait until BOTH parent and child are registered/alive
    assert wait_until(fn -> agent_count() >= before + 2 end, 2000)

    assert :ok = NanoAgent.cancel(parent_id)

    # both parent and child should be gone (subtree reaped via the linked supervisor)
    assert wait_until(fn -> agent_count() <= before end, 2000)
  end
end
