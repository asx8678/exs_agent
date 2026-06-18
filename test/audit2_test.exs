defmodule NanoAgent.Audit2Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Store, Metrics, Export, Context, Tools, Provider.OpenAI}

  setup do
    Store.clear()
    on_exit(fn -> Application.put_env(:nano_agent, :sandbox, []) end)
    :ok
  end

  test "cancel never clobbers a finished run's status" do
    Store.register("r1", "p")
    Store.finish("r1", %NanoAgent.Result{status: :ok, summary: "done"})
    # a late cancel must not flip :ok -> :cancelled
    Store.cancel("r1")
    assert Store.get("r1").status == :ok
  end

  test "glob filters matches outside the sandbox root" do
    root = Path.join(System.tmp_dir!(), "glob_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "inside.ex"), "x")
    Application.put_env(:nano_agent, :sandbox, root: root, enforce: true)

    # absolute pattern escaping the root yields no leaked matches
    out = Tools.run("glob", %{"pattern" => "/etc/*"})
    refute out =~ "/etc/passwd"

    inside = Tools.run("glob", %{"pattern" => Path.join(root, "*.ex")})
    assert inside =~ "inside.ex"
  end

  test "metrics and export survive a record with nil tokens" do
    Store.register("r2", "p")
    # simulate a malformed/legacy record
    Store.checkpoint("r2", %{tokens: nil})
    _ = Store.list()

    assert %{tokens: %{input: _, output: _}} = Metrics.snapshot()
    assert {:ok, md} = Export.markdown("r2")
    assert md =~ "tokens:"
  end

  test "context compaction never leaves an orphan tool_result at the window start" do
    pairs =
      for i <- 1..30 do
        [
          %{
            role: "assistant",
            content: [%{"type" => "tool_use", "id" => "t#{i}", "name" => "bash", "input" => %{}}]
          },
          %{
            role: "user",
            content: [%{"type" => "tool_result", "tool_use_id" => "t#{i}", "content" => "ok"}]
          }
        ]
      end
      |> List.flatten()

    messages = [%{role: "user", content: "plan"} | pairs]
    # force a window size that would otherwise start on a tool_result
    compacted = Context.compact(messages, max_messages: 40, keep_recent: 15)

    [_first, _summary | tail] = compacted
    refute match?(%{role: "user", content: [%{"type" => "tool_result"} | _]}, hd(tail))
  end

  test "OpenAI emits a string (not nil) for a contentless tool-less assistant turn" do
    msgs = OpenAI.to_openai_messages([%{role: "assistant", content: []}], nil)
    assert [%{role: "assistant", content: ""}] = msgs
  end
end
