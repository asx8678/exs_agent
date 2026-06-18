defmodule NanoAgent.Provider.OpenAI do
  @moduledoc """
  OpenAI Chat Completions provider — demonstrates the `NanoAgent.Provider`
  abstraction with a second wire format. Translates the internal Anthropic-style
  message/tool shape to OpenAI's and back.

  The translation functions (`to_openai_messages/1`, `to_openai_tools/1`,
  `from_openai/1`) are pure and unit-tested offline; the HTTP path is exercised
  against the live API. Enable with
  `config :nano_agent, provider: NanoAgent.Provider.OpenAI`.
  """
  @behaviour NanoAgent.Provider

  @endpoint ~c"https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o"
  @max_tokens 4096

  @impl true
  def chat(messages, tools, opts \\ []) do
    api_key = System.get_env("OPENAI_API_KEY") || raise "OPENAI_API_KEY not set"
    model = opts[:model] || System.get_env("OPENAI_MODEL") || @default_model

    msgs = to_openai_messages(messages, opts[:system])

    payload = %{
      model: model,
      # newer OpenAI models reject `max_tokens`; `max_completion_tokens` is current
      max_completion_tokens: opts[:max_tokens] || @max_tokens,
      messages: msgs,
      tools: to_openai_tools(tools),
      tool_choice: "auto"
    }

    body = payload |> :json.encode() |> IO.iodata_to_binary()
    headers = [{~c"authorization", String.to_charlist("Bearer " <> api_key)}]
    request = {@endpoint, headers, ~c"application/json", body}

    case :httpc.request(:post, request, http_opts(), body_format: :binary) do
      {:ok, {{_v, 200, _r}, _h, resp}} -> {:ok, from_openai(:json.decode(resp))}
      {:ok, {{_v, status, _r}, headers, resp}} -> {:error, {:http, status, headers, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---- request translation (Anthropic-style -> OpenAI) ----

  @doc false
  def to_openai_messages(messages, system \\ nil) do
    sys = if system, do: [%{role: "system", content: system}], else: []
    sys ++ Enum.flat_map(messages, &translate_message/1)
  end

  defp translate_message(%{role: "user", content: content}) when is_binary(content),
    do: [%{role: "user", content: content}]

  defp translate_message(%{role: "user", content: parts}) when is_list(parts) do
    # Anthropic tool_result blocks -> OpenAI role:"tool" messages.
    Enum.map(parts, fn
      %{"type" => "tool_result", "tool_use_id" => id, "content" => out} ->
        %{role: "tool", tool_call_id: id, content: out}

      %{"type" => "text", "text" => t} ->
        %{role: "user", content: t}
    end)
  end

  defp translate_message(%{role: "assistant", content: parts}) when is_list(parts) do
    text =
      parts
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map_join("\n", & &1["text"])

    tool_calls =
      parts
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn tu ->
        %{
          id: tu["id"],
          type: "function",
          function: %{
            name: tu["name"],
            arguments: :json.encode(tu["input"]) |> IO.iodata_to_binary()
          }
        }
      end)

    # OpenAI allows content:null ONLY when tool_calls are present; otherwise it must
    # be a string. Use "" rather than nil for a contentless, tool-less assistant turn.
    if tool_calls == [] do
      [%{role: "assistant", content: text}]
    else
      content = if text == "", do: nil, else: text
      [%{role: "assistant", content: content, tool_calls: tool_calls}]
    end
  end

  defp translate_message(other), do: [other]

  @doc false
  def to_openai_tools(tools) do
    Enum.map(tools, fn t ->
      %{
        type: "function",
        function: %{
          name: t.name,
          description: t.description,
          parameters: t.input_schema
        }
      }
    end)
  end

  # ---- response translation (OpenAI -> normalized Anthropic-style) ----

  @doc false
  def from_openai(%{"choices" => [%{"message" => msg} | _]} = resp) do
    text = msg["content"]
    tool_calls = msg["tool_calls"] || []

    content =
      maybe_text(text) ++
        Enum.map(tool_calls, fn tc ->
          %{
            "type" => "tool_use",
            "id" => tc["id"],
            "name" => tc["function"]["name"],
            "input" => decode_args(tc["function"]["arguments"])
          }
        end)

    %{
      "content" => content,
      "stop_reason" => if(tool_calls == [], do: "end_turn", else: "tool_use"),
      "usage" => %{
        "input_tokens" => get_in(resp, ["usage", "prompt_tokens"]) || 0,
        "output_tokens" => get_in(resp, ["usage", "completion_tokens"]) || 0
      }
    }
  end

  def from_openai(_),
    do: %{
      "content" => [],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
    }

  defp maybe_text(nil), do: []
  defp maybe_text(""), do: []
  defp maybe_text(t), do: [%{"type" => "text", "text" => t}]

  defp decode_args(nil), do: %{}

  defp decode_args(s) do
    :json.decode(s)
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
