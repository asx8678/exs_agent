defmodule NanoAgent.Provider.Mock do
  @moduledoc """
  Deterministic mock provider for tests and offline demos — no network.

  Configure via `:nano_agent, :mock`:

    * a `fun/3` `(messages, tools, opts) -> {:ok, response}` for full control, or
    * a list of responses used as a queue. The Nth provider call (i.e. after N
      assistant turns already exist in the history) returns the Nth list element.

  Build responses with `end_turn/1` and `tool_use/3`.
  """
  @behaviour NanoAgent.Provider

  @impl true
  def chat(messages, tools, opts) do
    case Application.get_env(:nano_agent, :mock) do
      fun when is_function(fun, 3) ->
        fun.(messages, tools, opts)

      list when is_list(list) and list != [] ->
        idx = Enum.count(messages, &(role(&1) == "assistant"))
        {:ok, Enum.at(list, idx, end_turn("mock: script exhausted"))}

      _ ->
        {:ok, end_turn("mock: no script configured")}
    end
  end

  @doc "A terminal assistant turn with text and no tool calls."
  def end_turn(text) do
    %{
      "content" => [%{"type" => "text", "text" => text}],
      "stop_reason" => "end_turn",
      "usage" => %{"input_tokens" => 3, "output_tokens" => 5}
    }
  end

  @doc "An assistant turn requesting a single tool call."
  def tool_use(id, name, input) do
    %{
      "content" => [%{"type" => "tool_use", "id" => id, "name" => name, "input" => input}],
      "stop_reason" => "tool_use",
      "usage" => %{"input_tokens" => 4, "output_tokens" => 6}
    }
  end

  defp role(%{role: r}), do: r
  defp role(%{"role" => r}), do: r
  defp role(_), do: nil
end
