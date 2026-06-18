defmodule NanoAgent.Export do
  @moduledoc """
  Render a persisted run to JSON or human-readable Markdown — useful for sharing,
  debugging, or archiving a session transcript.
  """
  alias NanoAgent.Store

  @spec json(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def json(run_id) do
    case Store.get(run_id) do
      nil -> {:error, :not_found}
      rec -> {:ok, rec |> jsonable() |> :json.encode() |> IO.iodata_to_binary()}
    end
  end

  @spec markdown(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def markdown(run_id) do
    case Store.get(run_id) do
      nil -> {:error, :not_found}
      rec -> {:ok, render(rec)}
    end
  end

  # ---- markdown rendering ----

  defp render(rec) do
    """
    # Run #{rec.id}

    - **status:** #{rec.status}
    - **tokens:** in #{tok(rec, :input)} / out #{tok(rec, :output)}
    - **tool calls:** #{rec.tool_calls} · **iterations:** #{rec.iterations}

    ## Plan

    #{rec.plan}
    #{todos_md(Map.get(rec, :todos))}
    ## Transcript

    #{Enum.map_join(rec.messages, "\n\n", &message_md/1)}

    ## Summary

    #{rec.summary}
    """
  end

  defp tok(rec, key), do: Map.get(rec.tokens || %{}, key, 0)

  defp todos_md(nil), do: ""
  defp todos_md([]), do: ""

  defp todos_md(items) do
    mark = %{"completed" => "[x]", "in_progress" => "[~]", "pending" => "[ ]"}

    lines =
      Enum.map_join(items, "\n", fn t -> "- #{mark[t["status"]] || "[ ]"} #{t["content"]}" end)

    "\n## Todos\n\n#{lines}\n"
  end

  defp message_md(%{role: "user", content: c}) when is_binary(c), do: "### User\n\n#{c}"

  defp message_md(%{role: "assistant", content: blocks}) when is_list(blocks),
    do: "### Assistant\n\n" <> Enum.map_join(blocks, "\n\n", &block_md/1)

  defp message_md(%{role: "user", content: blocks}) when is_list(blocks),
    do: "### Tool results\n\n" <> Enum.map_join(blocks, "\n\n", &block_md/1)

  defp message_md(other), do: "```\n#{inspect(other)}\n```"

  defp block_md(%{"type" => "text", "text" => t}), do: t

  defp block_md(%{"type" => "tool_use", "name" => n, "input" => input}),
    do: "**→ #{n}**\n\n```json\n#{:json.encode(input) |> IO.iodata_to_binary()}\n```"

  defp block_md(%{"type" => "tool_result", "content" => c}), do: "```\n#{c}\n```"
  defp block_md(other), do: "```\n#{inspect(other)}\n```"

  # ---- json safety ----

  defp jsonable(%{} = m) when not is_struct(m),
    do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)

  defp jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  defp jsonable(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp jsonable(v) when is_atom(v), do: to_string(v)
  defp jsonable(v), do: inspect(v)
end
