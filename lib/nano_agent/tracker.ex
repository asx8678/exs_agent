defmodule NanoAgent.Tracker do
  @moduledoc """
  In-memory view of recent activity. Subscribes to `NanoAgent.Events` and keeps a
  capped ring buffer of events plus a per-run rollup, so the dashboard has initial
  state to paint before the live SSE stream takes over. M4 adds the durable store.
  """
  use GenServer

  @max_events 250

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "Recent events, oldest first."
  def events, do: GenServer.call(__MODULE__, :events)

  @doc "Per-run rollup: %{ref_string => %{status, tool_calls, last_at}}."
  def runs, do: GenServer.call(__MODULE__, :runs)

  @impl true
  def init(_) do
    NanoAgent.Events.subscribe(:all)
    {:ok, %{events: [], runs: %{}}}
  end

  @impl true
  def handle_info({:nano_event, e}, state) do
    events = Enum.take([e | state.events], @max_events)
    {:noreply, %{state | events: events, runs: rollup(state.runs, e)}}
  end

  @impl true
  def handle_call(:events, _from, state), do: {:reply, Enum.reverse(state.events), state}
  def handle_call(:runs, _from, state), do: {:reply, state.runs, state}

  defp rollup(runs, %{ref: ref, type: type, at: at}) do
    key = inspect(ref)
    run = Map.get(runs, key, %{status: :running, tool_calls: 0, last_at: at})

    run =
      case type do
        :tool_call -> %{run | tool_calls: run.tool_calls + 1, last_at: at}
        t when t in [:ok, :error, :max_iterations] -> %{run | status: t, last_at: at}
        _ -> %{run | last_at: at}
      end

    Map.put(runs, key, run)
  end
end
