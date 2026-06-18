defmodule NanoAgent.Provider.AnthropicStream do
  @moduledoc """
  Streaming Anthropic provider (SSE over `:httpc`). The event assembly lives in the
  pure, unit-tested `NanoAgent.SSE` module; this module only does HTTP I/O and
  forwards `opts[:on_delta]` for live text rendering.

  Enable with `config :nano_agent, provider: NanoAgent.Provider.AnthropicStream`.
  The HTTP path is exercised against the live API; the parser is covered offline.
  """
  @behaviour NanoAgent.Provider

  alias NanoAgent.SSE

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
      {:ok, request_id} -> collect(request_id, SSE.new(), opts[:on_delta])
      {:error, reason} -> {:error, reason}
    end
  end

  defp collect(id, acc, on_delta) do
    receive do
      {:http, {^id, :stream_start, _headers}} ->
        collect(id, acc, on_delta)

      {:http, {^id, :stream, chunk}} ->
        collect(id, SSE.feed(acc, chunk, on_delta), on_delta)

      {:http, {^id, :stream_end, _headers}} ->
        {:ok, SSE.finalize(acc)}

      {:http, {^id, {:error, reason}}} ->
        {:error, reason}

      {:http, {^id, {{_v, status, _r}, _h, body}}} ->
        {:error, {:http, status, body}}
    after
      120_000 -> {:error, :timeout}
    end
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
