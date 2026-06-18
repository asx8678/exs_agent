defmodule NanoAgent.Provider.Anthropic do
  @moduledoc """
  Anthropic Messages API provider using OTP's built-in `:httpc` and `:json`
  (zero external dependencies). Non-streaming; see `NanoAgent.Provider.AnthropicStream`
  for the SSE variant used by the dashboard.
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
      tools: tools
    }

    payload = if sys = opts[:system], do: Map.put(payload, :system, sys), else: payload
    body = payload |> :json.encode() |> IO.iodata_to_binary()

    headers = [
      {~c"x-api-key", String.to_charlist(api_key)},
      {~c"anthropic-version", @version}
    ]

    request = {@endpoint, headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts(), body_format: :binary) do
      {:ok, {{_http, 200, _reason}, _headers, resp_body}} ->
        {:ok, :json.decode(resp_body)}

      {:ok, {{_http, status, _reason}, _headers, resp_body}} ->
        {:error, {:http, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_opts do
    ssl_opts = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]

    [ssl: ssl_opts, timeout: 120_000, connect_timeout: 30_000]
  end
end
