defmodule NanoAgent.Planner do
  @moduledoc """
  Decomposes a high-level goal into an ordered set of `NanoAgent.Plan`s using a
  single LLM call with a `submit_plan` structured-output tool. Falls back to a
  one-plan decomposition if the model declines to call the tool.
  """
  alias NanoAgent.{LLM, Plan}

  @system """
  You are a planning module. Break a goal into the MINIMAL set of self-contained
  sub-plans an execution agent can carry out independently. Each sub-plan must be
  doable by one agent with file and shell tools. Use `depends_on` to express
  ordering when one plan needs another's output. Prefer few plans. Call
  `submit_plan` exactly once.
  """

  @spec decompose(String.t()) ::
          {:ok, [Plan.t()], %{input: non_neg_integer, output: non_neg_integer}} | {:error, term()}
  def decompose(goal) do
    messages = [%{role: "user", content: "Goal:\n#{goal}"}]

    case LLM.chat(messages, [submit_plan_spec()], system: @system) do
      {:ok, %{"content" => content} = resp} ->
        {:ok, extract_plans(content, goal), usage(resp)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp usage(%{"usage" => %{} = u}),
    do: %{input: u["input_tokens"] || 0, output: u["output_tokens"] || 0}

  defp usage(_), do: %{input: 0, output: 0}

  defp extract_plans(content, goal) do
    with %{"input" => %{"plans" => raw}} <-
           Enum.find(content, &(&1["type"] == "tool_use" and &1["name"] == "submit_plan")),
         plans when plans != [] <- to_plans(raw) do
      sanitize(plans)
    else
      _ -> [%Plan{id: "1", description: goal, depends_on: []}]
    end
  end

  # Guard against malformed model output: duplicate ids, self-dependencies, and
  # dependencies on ids that don't exist (which would otherwise wrongly block a plan).
  defp sanitize(plans) do
    plans = Enum.uniq_by(plans, & &1.id)
    ids = MapSet.new(plans, & &1.id)

    Enum.map(plans, fn p ->
      deps =
        p.depends_on
        |> Enum.reject(&(&1 == p.id))
        |> Enum.filter(&MapSet.member?(ids, &1))
        |> Enum.uniq()

      %{p | depends_on: deps}
    end)
  end

  defp to_plans(raw) when is_list(raw) do
    for %{"id" => id, "description" => desc} = p <- raw do
      %Plan{
        id: to_string(id),
        description: desc,
        depends_on: Enum.map(Map.get(p, "depends_on", []), &to_string/1)
      }
    end
  end

  defp to_plans(_), do: []

  defp submit_plan_spec do
    %{
      name: "submit_plan",
      description: "Submit the decomposition of the goal into ordered sub-plans.",
      input_schema: %{
        type: "object",
        properties: %{
          plans: %{
            type: "array",
            items: %{
              type: "object",
              properties: %{
                id: %{type: "string", description: "Unique id, e.g. \"1\""},
                description: %{
                  type: "string",
                  description: "A self-contained instruction for one agent"
                },
                depends_on: %{type: "array", items: %{type: "string"}}
              },
              required: ["id", "description"]
            }
          }
        },
        required: ["plans"]
      }
    }
  end
end
