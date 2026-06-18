defmodule NanoAgent.Metrics do
  @moduledoc """
  Aggregate stats over persisted runs: counts by status, total tokens, and agent
  duration percentiles. Computed on demand from `NanoAgent.Store` — cheap at the
  scales this is meant for.
  """

  alias NanoAgent.Store

  @spec snapshot() :: map()
  def snapshot do
    runs = Store.list()
    finished = Enum.reject(runs, &(&1.status == :running))
    durations = finished |> Enum.map(&(&1.updated_at - &1.started_at)) |> Enum.sort()

    tokens =
      Enum.reduce(runs, %{input: 0, output: 0}, fn r, acc ->
        %{input: acc.input + r.tokens.input, output: acc.output + r.tokens.output}
      end)

    %{
      total: length(runs),
      by_status: Enum.frequencies_by(runs, & &1.status),
      tokens: tokens,
      duration_ms: %{
        p50: percentile(durations, 50),
        p95: percentile(durations, 95),
        count: length(durations)
      }
    }
  end

  defp percentile([], _p), do: 0

  defp percentile(sorted, p) do
    idx = max(round(p / 100 * length(sorted)) - 1, 0)
    Enum.at(sorted, idx)
  end
end
