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

  # Cast so a slow/syncing DETS process can't serialize or time out agent startup.
  # Ordering with later checkpoint/finish from the same agent is preserved (mailbox).
  def register(run_id, plan), do: GenServer.cast(__MODULE__, {:register, run_id, plan})

  # Fire-and-forget: per-iteration checkpoints must not serialize agents behind
  # one DETS process. Loss of the last in-flight checkpoint on a hard crash is
  # acceptable — resume re-issues at most the final tool exchange.
  def checkpoint(run_id, fields), do: GenServer.cast(__MODULE__, {:checkpoint, run_id, fields})

  def finish(run_id, result),
    do: GenServer.call(__MODULE__, {:finish, run_id, result})

  def cancel(run_id), do: GenServer.call(__MODULE__, {:cancel, run_id})
  def get(run_id), do: GenServer.call(__MODULE__, {:get, run_id})
  def list, do: GenServer.call(__MODULE__, :list)
  def running, do: GenServer.call(__MODULE__, :running)
  def clear, do: GenServer.call(__MODULE__, :clear)

  # ---- callbacks ----

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    dir = Application.get_env(:nano_agent, :data_dir, "data")
    File.mkdir_p!(dir)
    path = dir |> Path.join("runs.dets") |> String.to_charlist()
    {:ok, _} = :dets.open_file(@table, file: path, type: :set, auto_save: 5_000)
    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :dets.sync(@table)
    :dets.close(@table)
  end

  @impl true
  def handle_cast({:register, run_id, plan}, state) do
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
    prune(Application.get_env(:nano_agent, :max_stored_runs, 1000))
    {:noreply, state}
  end

  def handle_cast({:checkpoint, run_id, fields}, state) do
    update(run_id, fn rec -> Map.merge(rec, Map.put(fields, :updated_at, now())) end)
    {:noreply, state}
  end

  @impl true
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

    :dets.sync(@table)
    {:reply, :ok, state}
  end

  def handle_call({:cancel, run_id}, _from, state) do
    # Only a still-running run can be cancelled — never clobber a finished status
    # (races with normal completion).
    update(run_id, fn
      %{status: :running} = rec -> %{rec | status: :cancelled, updated_at: now()}
      rec -> rec
    end)

    :dets.sync(@table)
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

  # Keep at most `max` runs, deleting the oldest *finished* ones first so in-flight
  # runs are never dropped.
  defp prune(max) when is_integer(max) and max > 0 do
    all =
      :dets.foldl(fn {id, rec}, acc -> [{id, rec.started_at, rec.status} | acc] end, [], @table)

    over = length(all) - max

    if over > 0 do
      all
      |> Enum.filter(fn {_id, _at, status} -> status != :running end)
      |> Enum.sort_by(fn {_id, at, _status} -> at end)
      |> Enum.take(over)
      |> Enum.each(fn {id, _at, _status} -> :dets.delete(@table, id) end)
    end
  end

  defp prune(_), do: :ok
end
