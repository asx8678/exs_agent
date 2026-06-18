defmodule NanoAgent.Provider.AnthropicStream do
  @moduledoc """
  Streaming Anthropic provider (SSE over `:httpc`). Assembles the streamed events
  into the same normalized response shape the non-streaming provider returns, and
  invokes `opts[:on_delta]` with `%{type: :text, text: chunk}` for live rendering.

  Use by setting `config :nano_agent, provider: NanoAgent.Provider.AnthropicStream`.
  Note: exercised against the live API (no offline test) — the happy path is
  covered; tune to taste for your account.
  """
  @behaviour NanoAgent.Provider

  @endpoint ~c"https://api.anthropic.com/v1/messages"
  @version ~c"2023-06-01"
  @default_model "claude-sonnet-4-6"
  @max_tokens 4096

  @impl true
  def chat(messages, tools, opts \\ []) do
    api_key = System.get_env("ANTHROPIC_API_KEY") || raise "ANTHROPIC_API_KEY not set"
    model = opts[:model] || System.get_env("ANTHROPIC_MODEL") || @default_model

    payload = %{
      model: model,
      max_tokens: opts[:max_tokens] || @max_tokens,
      messages: messages,
      tools: tools,
      stream: true
    }

    payload = if sys = opts[:system], do: Map.put(payload, :system, sys), else: payload
    body = payload |> :json.encode() |> IO.iodata_to_binary()

    headers = [
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", @version}
    ]

    request = {@endpoint, headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts(),
           sync: false,
           stream: :self,
           body_format: :binary
         ) do
      {:ok, request_id} ->
        collect(request_id, init_acc(), opts[:on_delta])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp init_acc do
    %{buffer: "", blocks: %{}, order: [], stop_reason: nil, usage: %{input: 0, output: 0}}
  end

  defp collect(id, acc, on_delta) do
    receive do
      {:http, {^id, :stream_start, _headers}} ->
        collect(id, acc, on_delta)

      {:http, {^id, :stream, chunk}} ->
        collect(id, consume(acc, chunk, on_delta), on_delta)

      {:http, {^id, :stream_end, _headers}} ->
        {:ok, finalize(acc)}

      {:http, {^id, {:error, reason}}} ->
        {:error, reason}

      {:http, {^id, {{_v, status, _r}, _h, body}}} ->
        {:error, {:http, status, body}}
    after
      120_000 -> {:error, :timeout}
    end
  end

  # Split the rolling buffer on SSE event boundaries ("\n\n") and process each.
  defp consume(acc, chunk, on_delta) do
    data = acc.buffer <> chunk
    parts = String.split(data, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    acc = Enum.reduce(complete, %{acc | buffer: rest}, &handle_event(&2, &1, on_delta))
    acc
  end

  defp handle_event(acc, raw, on_delta) do
    json =
      raw
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("", fn "data:" <> rest -> String.trim(rest) end)

    if json == "" do
      acc
    else
      apply_event(acc, :json.decode(json), on_delta)
    end
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
    block = Map.get(acc.blocks, i, %{type: "text", text: ""})

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

  defp apply_event(acc, %{"type" => "message_delta", "delta" => d} = e, _) do
    out = get_in(e, ["usage", "output_tokens"]) || acc.usage.output
    %{acc | stop_reason: d["stop_reason"] || acc.stop_reason, usage: %{acc.usage | output: out}}
  end

  defp apply_event(acc, _other, _), do: acc

  defp finalize(acc) do
    content =
      acc.order
      |> Enum.uniq()
      |> Enum.map(&Map.get(acc.blocks, &1))
      |> Enum.map(fn
        %{type: "text", text: t} ->
          %{"type" => "text", "text" => t}

        %{type: "tool_use", id: id, name: n, json: j} ->
          %{"type" => "tool_use", "id" => id, "name" => n, "input" => decode_input(j)}
      end)

    %{
      "content" => content,
      "stop_reason" => acc.stop_reason,
      "usage" => %{"input_tokens" => acc.usage.input, "output_tokens" => acc.usage.output}
    }
  end

  defp decode_input(""), do: %{}

  defp decode_input(j) do
    :json.decode(j)
  rescue
    _ -> %{}
  end

  defp http_opts do
    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    [ssl: ssl_opts, timeout: 120_000, connect_timeout: 30_000]
  end
end
