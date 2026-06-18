defmodule NanoAgent.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Zero-dep pub/sub for live events (Registry-based).
        NanoAgent.Events,
        # In-memory rollup of recent activity for the dashboard.
        NanoAgent.Tracker,
        # Durable run history (DETS) for inspection + crash-resume.
        NanoAgent.Store,
        # Human-in-the-loop approval gate for flagged tool calls.
        NanoAgent.Approvals,
        # Spawns one ephemeral Agent process per dispatched plan.
        {DynamicSupervisor, name: NanoAgent.AgentSupervisor, strategy: :one_for_one},
        # Bounded concurrency for goal fan-out.
        {Task.Supervisor, name: NanoAgent.TaskSupervisor},
        # Holds the goal, dispatches plans to agents, collects results.
        NanoAgent.Orchestrator
      ] ++ maybe_web()

    opts = [strategy: :one_for_one, name: NanoAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_web do
    if Application.get_env(:nano_agent, :web_enabled, true) do
      [NanoAgent.Web]
    else
      []
    end
  end
end
