defmodule NanoAgent.Resume do
  @moduledoc """
  Crash recovery. Any run left in `:running` state in `NanoAgent.Store` (i.e. its
  agent died before reporting) is re-spawned from its persisted message history and
  driven to completion. Call `resume_all/0` on boot, or manually.
  """
  require Logger
  alias NanoAgent.{Store, Agent, Result}

  @agent_timeout 180_000

  @spec resume_all(keyword()) :: [{String.t(), Result.t()}]
  def resume_all(opts \\ []) do
    runs = Store.running()
    Logger.info("resuming #{length(runs)} interrupted run(s)")
    Enum.map(runs, &resume_run(&1, opts))
  end

  defp resume_run(run, opts) do
    timeout = opts[:agent_timeout] || @agent_timeout
    ref = make_ref()

    {:ok, pid} =
      DynamicSupervisor.start_child(
        NanoAgent.AgentSupervisor,
        {Agent,
         %{
           ref: ref,
           run_id: run.id,
           plan: run.plan,
           orchestrator: self(),
           messages: run.messages,
           iterations: run.iterations,
           tool_calls: run.tool_calls,
           tokens: run.tokens
         }}
      )

    mref = Process.monitor(pid)

    receive do
      {:agent_done, ^pid, %Result{} = result} ->
        Process.demonitor(mref, [:flush])
        {run.id, result}

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {run.id, %Result{status: :error, summary: "resume crashed", error: reason}}
    after
      timeout ->
        Process.demonitor(mref, [:flush])
        DynamicSupervisor.terminate_child(NanoAgent.AgentSupervisor, pid)
        {run.id, %Result{status: :error, summary: "resume timed out", error: :timeout}}
    end
  end
end
