defmodule NanoAgent.Store do
  @moduledoc """
  Durable run history backed by DETS (built into OTP — zero external deps).
  Persists one record per agent run: plan, status, message history, iteration
  count, tokens, tool calls, summary, timestamps.

  The message history is what makes crash-resume possible: agents checkpoint after
  every iteration, so an interrupted run can be re-spawned from its last good state
  (see `NanoAgent.Resume`).
  """
  use GenServer

  @table :nano_runs

  # ---- API ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def register(run_id, plan), do: GenServer.call(__MODULE__, {:register, run_id, plan})
  def checkpoint(run_id, fields), do: GenServer.call(__MODULE__, {:checkpoint, run_id, fields})

  def finish(run_id, result),
    do: GenServer.call(__MODULE__, {:finish, run_id, result})

  def get(run_id), do: GenServer.call(__MODULE__, {:get, run_id})
  def list, do: GenServer.call(__MODULE__, :list)
  def running, do: GenServer.call(__MODULE__, :running)
  def clear, do: GenServer.call(__MODULE__, :clear)

  # ---- callbacks ----

  @impl true
  def init(_) do
    dir = Application.get_env(:nano_agent, :data_dir, "data")
    File.mkdir_p!(dir)
    path = dir |> Path.join("runs.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: path, type: :set)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state), do: :dets.close(@table)

  @impl true
  def handle_call({:register, run_id, plan}, _from, state) do
    now = System.system_time(:millisecond)

    record = %{
      id: run_id,
      plan: plan,
      status: :running,
      messages: [],
      iterations: 0,
      tool_calls: 0,
      tokens: %{input: 0, output: 0},
      summary: "",
      started_at: now,
      updated_at: now
    }

    :dets.insert(@table, {run_id, record})
    {:reply, :ok, state}
  end

  def handle_call({:checkpoint, run_id, fields}, _from, state) do
    update(run_id, fn rec -> Map.merge(rec, Map.put(fields, :updated_at, now())) end)
    {:reply, :ok, state}
  end

  def handle_call({:finish, run_id, result}, _from, state) do
    update(run_id, fn rec ->
      %{
        rec
        | status: result.status,
          summary: result.summary,
          tokens: result.tokens,
          tool_calls: result.tool_calls,
          iterations: result.iterations,
          updated_at: now()
      }
    end)

    {:reply, :ok, state}
  end

  def handle_call({:get, run_id}, _from, state) do
    {:reply, fetch(run_id), state}
  end

  def handle_call(:list, _from, state) do
    runs =
      :dets.foldl(fn {_id, rec}, acc -> [rec | acc] end, [], @table)
      |> Enum.sort_by(& &1.started_at, :desc)

    {:reply, runs, state}
  end

  def handle_call(:running, _from, state) do
    runs =
      :dets.foldl(
        fn
          {_id, %{status: :running} = rec}, acc -> [rec | acc]
          _, acc -> acc
        end,
        [],
        @table
      )

    {:reply, runs, state}
  end

  def handle_call(:clear, _from, state) do
    :dets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  # ---- helpers ----

  defp fetch(run_id) do
    case :dets.lookup(@table, run_id) do
      [{^run_id, rec}] -> rec
      _ -> nil
    end
  end

  defp update(run_id, fun) do
    case fetch(run_id) do
      nil -> :ok
      rec -> :dets.insert(@table, {run_id, fun.(rec)})
    end
  end

  defp now, do: System.system_time(:millisecond)
end
