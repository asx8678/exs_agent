defmodule NanoAgent.Orchestrator do
  @moduledoc """
  Holds the high-level goal and decomposes it into plans. For each plan it
  starts one Agent process under the DynamicSupervisor, monitors it, and
  forwards the result (or failure) to whoever dispatched the plan.

  This is the "smart, stateful" half of Model A. Agents are the "ephemeral,
  headless" half — cheap BEAM processes, supervised and crash-isolated.
  """
  use GenServer
  require Logger

  # ---- Public API ----

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  Dispatch a plan. The result is delivered to `reporter` (defaults to the
  caller) as `{:done, ref, summary}` or `{:failed, ref, reason}`.
  Returns a `ref` to match on.
  """
  def dispatch(plan, reporter \\ self()) when is_binary(plan) do
    ref = make_ref()
    GenServer.cast(__MODULE__, {:dispatch, ref, plan, reporter})
    ref
  end

  # ---- Callbacks ----

  @impl true
  def init(_), do: {:ok, %{agents: %{}}}

  @impl true
  def handle_cast({:dispatch, ref, plan, reporter}, state) do
    spec = {NanoAgent.Agent, %{ref: ref, plan: plan, orchestrator: self()}}
    {:ok, pid} = DynamicSupervisor.start_child(NanoAgent.AgentSupervisor, spec)
    mref = Process.monitor(pid)

    Logger.info("dispatch #{inspect(pid)} :: #{String.slice(plan, 0, 60)}")

    agents = Map.put(state.agents, pid, %{ref: ref, mref: mref, reporter: reporter})
    {:noreply, %{state | agents: agents}}
  end

  @impl true
  def handle_info({:agent_done, pid, result}, state) do
    {meta, agents} = Map.pop(state.agents, pid)

    if meta do
      Process.demonitor(meta.mref, [:flush])
      send(meta.reporter, {:done, meta.ref, result})
      Logger.info("done #{inspect(pid)}")
    end

    {:noreply, %{state | agents: agents}}
  end

  # An agent that crashed before reporting -> surface the failure.
  def handle_info({:DOWN, _mref, :process, pid, reason}, state) do
    {meta, agents} = Map.pop(state.agents, pid)

    if meta && reason != :normal do
      Logger.error("crash #{inspect(pid)} :: #{inspect(reason)}")
      send(meta.reporter, {:failed, meta.ref, reason})
    end

    {:noreply, %{state | agents: agents}}
  end
end
