defmodule NanoAgent.Plan do
  @moduledoc "A single unit of work for one agent, with optional dependencies."

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          depends_on: [String.t()]
        }

  @enforce_keys [:id, :description]
  defstruct id: nil, description: nil, depends_on: []
end

defmodule NanoAgent.GoalReport do
  @moduledoc "Aggregated outcome of executing a goal across many plans."

  @type outcome :: %{plan: NanoAgent.Plan.t(), result: NanoAgent.Result.t()}

  @type t :: %__MODULE__{
          goal: String.t(),
          status: :ok | :partial | :failed,
          outcomes: [outcome],
          tokens: %{input: non_neg_integer, output: non_neg_integer}
        }

  defstruct goal: "", status: :ok, outcomes: [], tokens: %{input: 0, output: 0}
end
