defmodule NanoAgent.Provider do
  @moduledoc """
  Behaviour for LLM providers. A provider turns a list of messages + tool specs
  into a normalized response map:

      %{
        "content" => [
          %{"type" => "text", "text" => "..."} |
          %{"type" => "tool_use", "id" => "...", "name" => "...", "input" => %{...}}
        ],
        "stop_reason" => "tool_use" | "end_turn" | ...,
        "usage" => %{"input_tokens" => integer, "output_tokens" => integer}
      }

  Keeping the Anthropic-native shape as the normalized form keeps the agent loop
  simple; other providers (OpenAI, ...) translate into it.
  """

  @callback chat(messages :: [map()], tools :: [map()], opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
end
