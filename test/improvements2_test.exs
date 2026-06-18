defmodule NanoAgent.Improvements2Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Context, Safety, Provider.Mock}

  setup do
    on_exit(fn ->
      Application.delete_env(:nano_agent, :mock)
      Application.delete_env(:nano_agent, :max_run_tokens)
      Application.put_env(:nano_agent, :sandbox, [])
    end)

    :ok
  end

  describe "context compaction" do
    test "compacts middle pairs, keeps plan + recent window on pair boundaries" do
      pairs =
        for i <- 1..30 do
          [
            %{
              role: "assistant",
              content: [
                %{"type" => "tool_use", "id" => "t#{i}", "name" => "bash", "input" => %{}}
              ]
            },
            %{
              role: "user",
              content: [%{"type" => "tool_result", "tool_use_id" => "t#{i}", "content" => "ok"}]
            }
          ]
        end
        |> List.flatten()

      messages = [%{role: "user", content: "the plan"} | pairs]
      assert length(messages) == 61

      compacted = Context.compact(messages, max_messages: 40, keep_recent: 16)

      assert length(compacted) == 18
      assert hd(compacted).content == "the plan"

      [_first, summary | tail] = compacted
      assert summary.role == "user"
      assert summary.content =~ "Context compacted"
      assert summary.content =~ "bash"
      # the kept window starts on an assistant turn — no dangling tool_result
      assert hd(tail).role == "assistant"
      assert List.last(tail).role == "user"
    end

    test "leaves short histories untouched" do
      messages = [%{role: "user", content: "x"}]
      assert Context.compact(messages, max_messages: 40, keep_recent: 16) == messages
    end
  end

  test "per-run token budget stops the agent with :budget status" do
    Application.put_env(:nano_agent, :max_run_tokens, 5)

    Application.put_env(:nano_agent, :mock, fn _m, _t, _o ->
      {:ok, Mock.tool_use("t", "bash", %{"command" => "echo hi"})}
    end)

    assert {:ok, r} = NanoAgent.run("loop forever", 5_000)
    assert r.status == :budget
  end

  test "Retry-After header is honored and the call recovers" do
    ctr = :counters.new(1, [:atomics])

    Application.put_env(:nano_agent, :mock, fn _m, _t, _o ->
      n = :counters.get(ctr, 1)
      :counters.add(ctr, 1, 1)

      if n == 0 do
        {:error, {:http, 429, [{~c"retry-after", ~c"0"}], "rate limited"}}
      else
        {:ok, Mock.end_turn("after retry")}
      end
    end)

    assert {:ok, r} = NanoAgent.run("flaky", 5_000)
    assert r.summary =~ "after retry"
    assert :counters.get(ctr, 1) == 2
  end

  test "sandbox rejects symlink escape" do
    root = Path.join(System.tmp_dir!(), "sym_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.ln_s("/etc", Path.join(root, "escape"))
    Application.put_env(:nano_agent, :sandbox, root: root, enforce: true)

    assert {:error, :denied} = Safety.resolve("escape/passwd")
    assert {:ok, _} = Safety.resolve("legit.txt")
    File.rm_rf(root)
  end
end
