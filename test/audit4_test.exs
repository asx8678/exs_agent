defmodule NanoAgent.Audit4Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{SSE, Tools, GoalReport, Provider.OpenAI, Provider.Mock}

  setup do
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "SSE ignores a stray delta for an unstarted block (no crash, no fabricated block)" do
    acc =
      SSE.new()
      |> SSE.feed(
        ~s(data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}\n\n)
      )
      |> SSE.feed(
        ~s(data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}\n\n)
      )

    resp = SSE.finalize(acc)
    assert resp["content"] == []
    assert resp["stop_reason"] == "end_turn"
  end

  test "OpenAI emits tool messages before any user text, never interleaved" do
    parts = [
      %{"type" => "tool_result", "tool_use_id" => "a", "content" => "ra"},
      %{"type" => "text", "text" => "note"},
      %{"type" => "tool_result", "tool_use_id" => "b", "content" => "rb"}
    ]

    msgs = OpenAI.to_openai_messages([%{role: "user", content: parts}], nil)
    roles = Enum.map(msgs, & &1[:role])
    # both tool messages come before the user text
    assert roles == ["tool", "tool", "user"]
  end

  test "grep still works with the bounded directory walk" do
    tmp = Path.join(System.tmp_dir!(), "walk_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "sub"))
    File.write!(Path.join(tmp, "a.txt"), "alpha")
    File.write!(Path.join([tmp, "sub", "b.txt"]), "needle here")
    on_exit(fn -> File.rm_rf(tmp) end)

    out = Tools.run("grep", %{"pattern" => "needle", "path" => tmp})
    assert out =~ "b.txt"
  end

  test "planner sanitizes duplicate ids and bad deps; goal still runs all plans" do
    mock = fn _messages, tools, _o ->
      if Enum.any?(tools, &(&1[:name] == "submit_plan")) do
        {:ok,
         Mock.tool_use("p", "submit_plan", %{
           "plans" => [
             %{"id" => "1", "description" => "first", "depends_on" => ["1"]},
             %{"id" => "1", "description" => "dup id", "depends_on" => []},
             %{"id" => "2", "description" => "second", "depends_on" => ["99"]}
           ]
         })}
      else
        {:ok, Mock.end_turn("done")}
      end
    end

    Application.put_env(:nano_agent, :mock, mock)
    assert {:ok, %GoalReport{status: :ok, outcomes: outcomes}} = NanoAgent.run_goal("x")
    # dedup id -> 2 plans, both runnable (self-dep + unknown dep stripped)
    assert length(outcomes) == 2
  end
end
