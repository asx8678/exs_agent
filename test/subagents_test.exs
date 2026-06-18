defmodule NanoAgent.SubagentsTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Store, Provider.Mock}

  setup do
    Store.clear()

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

  defp has_tool_result?(messages) do
    Enum.any?(messages, fn
      %{role: "user", content: parts} when is_list(parts) ->
        Enum.any?(parts, &(&1["type"] == "tool_result"))

      _ ->
        false
    end)
  end

  test "an agent delegates a sub-task to a supervised child agent" do
    Application.put_env(:nano_agent, :subagents_enabled, true)

    Application.put_env(:nano_agent, :mock, fn messages, _tools, _o ->
      cond do
        # child agent's conversation (its plan contains the CHILD marker)
        String.contains?(last_user_text(messages), "CHILD") ->
          {:ok, Mock.end_turn("child finished the subtask")}

        # parent's second turn: it has the spawn_agent tool_result in history
        has_tool_result?(messages) ->
          {:ok, Mock.end_turn("parent done, delegated to child")}

        # parent's first turn: delegate
        true ->
          {:ok, Mock.tool_use("s1", "spawn_agent", %{"plan" => "CHILD do the subtask"})}
      end
    end)

    assert {:ok, r} = NanoAgent.run("delegate a piece of work to a child", 5_000)
    assert r.status == :ok
    assert r.summary =~ "parent done"
    assert r.tool_calls == 1

    # the child ran as its own persisted agent
    assert Enum.any?(Store.list(), &(&1.summary =~ "child finished"))
  end

  test "spawn_agent is unavailable and refused when subagents are disabled" do
    Application.put_env(:nano_agent, :subagents_enabled, false)

    Application.put_env(:nano_agent, :mock, fn messages, tools, _o ->
      # the tool must not be advertised when disabled
      refute Enum.any?(tools, &(&1[:name] == "spawn_agent"))

      if has_tool_result?(messages) do
        {:ok, Mock.end_turn("done")}
      else
        # force-call it anyway to prove the runtime guard refuses
        {:ok, Mock.tool_use("s1", "spawn_agent", %{"plan" => "x"})}
      end
    end)

    assert {:ok, r} = NanoAgent.run("try to spawn", 5_000)
    assert r.status == :ok
    # only the parent ran — no child was persisted
    assert length(Store.list()) == 1
  end
end
