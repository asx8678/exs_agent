defmodule NanoAgent.Result do
  @moduledoc "The outcome of an agent executing a plan."

  @type status :: :ok | :max_iterations | :budget | :error

  @type t :: %__MODULE__{
          status: status,
          summary: String.t(),
          iterations: non_neg_integer,
          tool_calls: non_neg_integer,
          tokens: %{input: non_neg_integer, output: non_neg_integer},
          error: term()
        }

  defstruct status: :ok,
            summary: "",
            iterations: 0,
            tool_calls: 0,
            tokens: %{input: 0, output: 0},
            error: nil
end
