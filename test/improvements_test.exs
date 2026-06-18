defmodule NanoAgent.ImprovementsTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{SSE, Provider.Mock}

  # ---- SSE parser (now pure + offline-testable) ----

  @stream """
  event: message_start
  data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}

  event: content_block_start
  data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":0}

  event: content_block_start
  data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"bash","input":{}}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"command\\":"}}

  event: content_block_delta
  data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\\"ls\\"}"}}

  event: content_block_stop
  data: {"type":"content_block_stop","index":1}

  event: message_delta
  data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":7}}

  event: message_stop
  data: {"type":"message_stop"}

  """

  test "assembles text + tool_use from a stream split on arbitrary boundaries" do
    {:ok, deltas} = Agent.start_link(fn -> [] end)
    on_delta = fn %{type: :text, text: t} -> Agent.update(deltas, &[t | &1]) end

    # feed in tiny 5-byte chunks to stress the buffering
    acc =
      @stream
      |> chunk_every(5)
      |> Enum.reduce(SSE.new(), fn c, acc -> SSE.feed(acc, c, on_delta) end)

    resp = SSE.finalize(acc)

    assert resp["stop_reason"] == "tool_use"
    assert resp["usage"] == %{"input_tokens" => 10, "output_tokens" => 7}

    assert [
             %{"type" => "text", "text" => "Hello world"},
             %{"type" => "tool_use", "name" => "bash", "input" => %{"command" => "ls"}}
           ] = resp["content"]

    assert Enum.reverse(Agent.get(deltas, & &1)) == ["Hello", " world"]
  end

  defp chunk_every(string, n) do
    string
    |> :binary.bin_to_list()
    |> Enum.chunk_every(n)
    |> Enum.map(&:binary.list_to_bin/1)
  end

  # ---- approval timeout (no more hangs) ----

  test "manual approval times out to deny instead of hanging the agent" do
    Application.put_env(:nano_agent, :approvals, :manual)
    Application.put_env(:nano_agent, :approval_tools, ["write"])
    Application.put_env(:nano_agent, :approval_timeout_ms, 80)

    on_exit(fn ->
      Application.put_env(:nano_agent, :approvals, :auto_approve)
      Application.put_env(:nano_agent, :approval_tools, [])
      Application.delete_env(:nano_agent, :approval_timeout_ms)
      Application.delete_env(:nano_agent, :mock)
    end)

    tmp = Path.join(System.tmp_dir!(), "noappr_#{System.unique_integer([:positive])}.txt")

    Application.put_env(:nano_agent, :mock, [
      Mock.tool_use("t1", "write", %{"path" => tmp, "content" => "should not happen"}),
      Mock.end_turn("finished without approval")
    ])

    # No one approves; the agent must not hang — the write is denied on timeout.
    assert {:ok, r} = NanoAgent.run("write a file", 5_000)
    assert r.status == :ok
    refute File.exists?(tmp)
  end
end
