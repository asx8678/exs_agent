defmodule NanoAgent do
  @moduledoc """
  Model A skeleton: an Elixir/OTP orchestrator that spawns ephemeral, supervised
  agent processes. Each agent runs an LLM tool-use loop over a plan and reports
  done. Agents are in-VM BEAM processes — KB-sized, microsecond spawn, crash-isolated.
  """

  alias NanoAgent.Orchestrator

  @doc """
  Run a high-level *goal*: decompose it into sub-plans and execute them across a
  supervised, dependency-aware, concurrency-capped fleet of agents.
  Returns `{:ok, %NanoAgent.GoalReport{}}` or `{:error, reason}`.
  """
  def run_goal(goal, opts \\ []) when is_binary(goal), do: NanoAgent.Goal.run(goal, opts)

  @doc """
  Fire-and-forget a single plan. Returns a `run_id` immediately; watch progress
  via the dashboard `/events` stream or `run_info/1`. Used by `POST /runs`.
  """
  def start_run(plan, _opts \\ []) when is_binary(plan) do
    run_id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    ref = make_ref()

    {:ok, _pid} =
      DynamicSupervisor.start_child(
        NanoAgent.AgentSupervisor,
        {NanoAgent.Agent,
         %{
           ref: ref,
           run_id: run_id,
           plan: plan,
           orchestrator: Process.whereis(NanoAgent.Orchestrator)
         }}
      )

    run_id
  end

  @doc "All persisted runs, newest first."
  def history, do: NanoAgent.Store.list()

  @doc "Fetch a single persisted run by id."
  def run_info(run_id), do: NanoAgent.Store.get(run_id)

  @doc "Re-run any interrupted (`:running`) runs from their saved state."
  def resume, do: NanoAgent.Resume.resume_all()

  @doc """
  Run a single plan and block until the agent reports back.
  Returns `{:ok, %NanoAgent.Result{}}` or `{:failed, reason}`.
  """
  def run(plan, timeout \\ 180_000) when is_binary(plan) do
    ref = Orchestrator.dispatch(plan)
    await(ref, timeout)
  end

  @doc """
  Dispatch many plans concurrently and collect every result.
  Returns `[{plan, {:ok, summary} | {:failed, reason}}]`.
  """
  def run_many(plans, timeout \\ 180_000) when is_list(plans) do
    plans
    |> Enum.map(fn plan -> {plan, Orchestrator.dispatch(plan)} end)
    |> Enum.map(fn {plan, ref} -> {plan, await(ref, timeout)} end)
  end

  defp await(ref, timeout) do
    receive do
      {:done, ^ref, summary} -> {:ok, summary}
      {:failed, ^ref, reason} -> {:failed, reason}
    after
      timeout -> {:failed, :timeout}
    end
  end
end
