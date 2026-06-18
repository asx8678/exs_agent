defmodule NanoAgent.Context do
  @moduledoc """
  Keeps an agent's message history from growing without bound.

  During the loop the history looks like:

      [user(plan), A1, U1, A2, U2, ..., An, Un]

  where each `Ai` is an assistant turn with `tool_use` blocks and each `Ui` is the
  matching `tool_result`. The two MUST stay together — dropping one half leaves a
  dangling tool call the API rejects. So compaction always drops whole `(Ai, Ui)`
  pairs from the middle, keeps the original plan plus a sliding window of recent
  pairs, and inserts one synthetic summary message describing what was dropped.
  """

  @doc "Compact `messages` if they exceed the configured limit; otherwise return as-is."
  def compact(messages, opts \\ []) do
    max = opts[:max_messages] || config(:context_max_messages, 40)
    keep = opts[:keep_recent] || config(:context_keep_recent, 16)

    if length(messages) <= max do
      messages
    else
      do_compact(messages, even(keep))
    end
  end

  defp do_compact([first | rest], keep) do
    kept_tail = rest |> Enum.take(-keep) |> drop_leading_tool_results()
    dropped = Enum.take(rest, max(length(rest) - length(kept_tail), 0))
    [first, %{role: "user", content: summarize(dropped)} | kept_tail]
  end

  # Defensive: a kept window must never begin with a tool_result whose assistant
  # tool_use was dropped (the API rejects an orphan tool_result).
  defp drop_leading_tool_results([
         %{role: "user", content: [%{"type" => "tool_result"} | _]} | rest
       ]),
       do: drop_leading_tool_results(rest)

  defp drop_leading_tool_results(msgs), do: msgs

  defp summarize(dropped) do
    tools =
      for %{role: "assistant", content: c} when is_list(c) <- dropped,
          block <- c,
          block["type"] == "tool_use" do
        block["name"]
      end

    exchanges = div(length(dropped), 2)
    tool_list = tools |> Enum.uniq() |> Enum.join(", ")

    "[Context compacted: #{exchanges} earlier tool exchange(s) omitted." <>
      tools_note(tool_list) <> " Continue the plan.]"
  end

  defp tools_note(""), do: ""
  defp tools_note(list), do: " Tools used: #{list}."

  defp even(n), do: n - rem(n, 2)

  defp config(key, default), do: Application.get_env(:nano_agent, key, default)
end
