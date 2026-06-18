defmodule NanoAgent.Provider.DeepSeek do
  @moduledoc """
  Official DeepSeek provider. DeepSeek's API is OpenAI-compatible, so this reuses
  the OpenAI wire-format translation (`NanoAgent.Provider.OpenAI`) and only swaps
  the endpoint, auth, and default model.

  Auth: `DEEPSEEK_API_KEY`. Model: `DEEPSEEK_MODEL` (defaults to `#{"deepseek-v4-pro"}`).
  Enable with `config :nano_agent, provider: NanoAgent.Provider.DeepSeek` (the default).
  """
  @behaviour NanoAgent.Provider

  alias NanoAgent.Provider.OpenAI

  @endpoint ~c"https://api.deepseek.com/chat/completions"
  @default_model "deepseek-v4-pro"
  @max_tokens 4096

  @impl true
  def chat(messages, tools, opts \\ []) do
    api_key = System.get_env("DEEPSEEK_API_KEY") || raise "DEEPSEEK_API_KEY not set"
    model = opts[:model] || System.get_env("DEEPSEEK_MODEL") || @default_model

    payload =
      %{
        model: model,
        max_tokens: opts[:max_tokens] || @max_tokens,
        messages: OpenAI.to_openai_messages(messages, opts[:system])
      }
      |> with_tools(tools)

    body = payload |> :json.encode() |> IO.iodata_to_binary()
    headers = [{~c"authorization", String.to_charlist("Bearer " <> api_key)}]
    request = {@endpoint, headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts(), body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, resp}} -> {:ok, OpenAI.from_openai(:json.decode(resp))}
      {:ok, {{_v, status, _r}, headers, resp}} -> {:error, {:http, status, headers, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp with_tools(payload, []), do: payload

  defp with_tools(payload, tools),
    do: Map.merge(payload, %{tools: OpenAI.to_openai_tools(tools), tool_choice: "auto"})

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
