defmodule NanoAgent.SSE do
  @moduledoc """
  Pure Anthropic SSE assembly — no I/O. Feed it raw byte chunks (split on any
  boundary) and it accumulates the streamed Messages events into the normalized
  response shape `NanoAgent.Provider` returns. Decoupled from `:httpc` so it can
  be unit-tested with recorded streams.

      acc = SSE.new()
      acc = SSE.feed(acc, "event: ...\\n\\ndata: ...\\n\\n")
      SSE.finalize(acc)  #=> %{"content" => [...], "stop_reason" => ..., "usage" => ...}

  Pass an `on_delta` callback to `feed/3` to observe text deltas live.
  """

  def new,
    do: %{buffer: "", blocks: %{}, order: [], stop_reason: nil, usage: %{input: 0, output: 0}}

  @doc "Consume a chunk; complete events are applied, the partial tail is buffered."
  def feed(acc, chunk, on_delta \\ nil) do
    data = acc.buffer <> chunk
    parts = String.split(data, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    Enum.reduce(complete, %{acc | buffer: rest}, &handle_event(&2, &1, on_delta))
  end

  @doc "Produce the normalized response from accumulated state."
  def finalize(acc) do
    content =
      acc.order
      |> Enum.uniq()
      |> Enum.map(&Map.get(acc.blocks, &1))
      |> Enum.map(fn
        %{type: "text", text: t} ->
          %{"type" => "text", "text" => t}

        %{type: "tool_use", id: id, name: n, json: j} ->
          %{"type" => "tool_use", "id" => id, "name" => n, "input" => decode_input(j)}

        _ ->
          nil
      end)
      |> Enum.reject(&is_nil/1)

    %{
      "content" => content,
      "stop_reason" => acc.stop_reason,
      "usage" => %{"input_tokens" => acc.usage.input, "output_tokens" => acc.usage.output}
    }
  end

  # ---- internals ----

  defp handle_event(acc, raw, on_delta) do
    json =
      raw
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("", fn "data:" <> rest -> String.trim(rest) end)

    if json == "", do: acc, else: apply_event(acc, :json.decode(json), on_delta)
  rescue
    _ -> acc
  end

  defp apply_event(acc, %{"type" => "message_start", "message" => %{"usage" => u}}, _) do
    %{acc | usage: %{acc.usage | input: u["input_tokens"] || 0}}
  end

  defp apply_event(
         acc,
         %{"type" => "content_block_start", "index" => i, "content_block" => cb},
         _
       ) do
    block =
      case cb["type"] do
        "tool_use" -> %{type: "tool_use", id: cb["id"], name: cb["name"], json: ""}
        _ -> %{type: "text", text: ""}
      end

    %{acc | blocks: Map.put(acc.blocks, i, block), order: acc.order ++ [i]}
  end

  defp apply_event(acc, %{"type" => "content_block_delta", "index" => i, "delta" => d}, on_delta) do
    # Ignore a delta for an index we never saw a content_block_start for, rather than
    # fabricating a malformed block.
    case Map.get(acc.blocks, i) do
      nil ->
        acc

      block ->
        block =
          case d["type"] do
            "text_delta" ->
              if on_delta, do: on_delta.(%{type: :text, text: d["text"]})
              %{block | text: (block[:text] || "") <> d["text"]}

            "input_json_delta" ->
              %{block | json: (block[:json] || "") <> d["partial_json"]}

            _ ->
              block
          end

        %{acc | blocks: Map.put(acc.blocks, i, block)}
    end
  end

  defp apply_event(acc, %{"type" => "message_delta", "delta" => d} = e, _) do
    out = get_in(e, ["usage", "output_tokens"]) || acc.usage.output
    %{acc | stop_reason: d["stop_reason"] || acc.stop_reason, usage: %{acc.usage | output: out}}
  end

  defp apply_event(acc, _other, _), do: acc

  defp decode_input(""), do: %{}

  defp decode_input(j) do
    :json.decode(j)
  rescue
    _ -> %{}
  end
end
