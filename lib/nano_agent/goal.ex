defmodule NanoAgent.Goal do
  @moduledoc """
  Executes a goal: decompose → schedule plans honoring `depends_on` → run ready
  plans concurrently (capped) → thread each plan's summary into its dependents →
  aggregate into a `NanoAgent.GoalReport`.

  Each plan runs in its own Task (under `NanoAgent.TaskSupervisor`), which spawns
  a supervised `Agent` and awaits its `%Result{}`. A failed plan is retried once;
  plans whose dependencies failed are skipped.
  """
  require Logger
  alias NanoAgent.{Planner, Agent, Result, GoalReport, Events}

  @agent_timeout 180_000

  @spec run(String.t(), keyword()) :: {:ok, GoalReport.t()} | {:error, term()}
  def run(goal, opts \\ []) do
    case Planner.decompose(goal) do
      {:ok, plans, planner_tokens} ->
        Logger.info("planned #{length(plans)} sub-plan(s) for goal")
        Events.publish(:goal, :planned, %{count: length(plans)})
        {:ok, schedule(goal, plans, planner_tokens, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- scheduler ----

  defp schedule(goal, plans, planner_tokens, opts) do
    cap = opts[:max_concurrency] || Application.get_env(:nano_agent, :max_concurrency, 5)
    timeout = opts[:agent_timeout] || @agent_timeout

    state = %{pending: plans, running: %{}, succeeded: %{}, outcomes: []}
    build_report(goal, drive(state, cap, timeout).outcomes, planner_tokens)
  end

  # Greedy pipeline: dispatch every ready plan as soon as there's capacity, then
  # block on the *next* completion (not the whole wave) so a fast plan can unblock
  # its dependents while a slow sibling is still running.
  defp drive(state, cap, timeout) do
    state = fill(state, cap, timeout)

    cond do
      map_size(state.running) > 0 ->
        state |> await_one(timeout) |> drive(cap, timeout)

      state.pending == [] ->
        state

      true ->
        # Nothing running, nothing runnable -> remaining plans are blocked.
        skipped = Enum.map(state.pending, &%{plan: &1, result: blocked_result()})
        %{state | pending: [], outcomes: state.outcomes ++ skipped}
    end
  end

  # Start ready plans until capacity is reached or none are ready.
  defp fill(state, cap, timeout) do
    if map_size(state.running) < cap do
      case take_ready(state) do
        {nil, _} ->
          state

        {plan, rest} ->
          task =
            Task.Supervisor.async_nolink(NanoAgent.TaskSupervisor, fn ->
              {plan, run_plan(plan, context_for(plan, state.succeeded), timeout)}
            end)

          %{state | pending: rest, running: Map.put(state.running, task.ref, plan)}
          |> fill(cap, timeout)
      end
    else
      state
    end
  end

  defp take_ready(state) do
    case Enum.split_with(state.pending, &ready?(&1, state.succeeded)) do
      {[], _not_ready} -> {nil, state.pending}
      {[plan | more_ready], not_ready} -> {plan, more_ready ++ not_ready}
    end
  end

  defp await_one(state, timeout) do
    receive do
      {ref, {plan, %Result{} = result}} when is_map_key(state.running, ref) ->
        Process.demonitor(ref, [:flush])
        record(state, ref, plan, result)

      {:DOWN, ref, :process, _pid, reason} when is_map_key(state.running, ref) ->
        plan = Map.fetch!(state.running, ref)
        record(state, ref, plan, %Result{status: :error, summary: "task crashed", error: reason})
    after
      timeout + 60_000 -> state
    end
  end

  defp record(state, ref, plan, result) do
    succeeded =
      if result.status == :ok,
        do: Map.put(state.succeeded, plan.id, result),
        else: state.succeeded

    %{
      state
      | running: Map.delete(state.running, ref),
        succeeded: succeeded,
        outcomes: state.outcomes ++ [%{plan: plan, result: result}]
    }
  end

  defp ready?(plan, succeeded), do: Enum.all?(plan.depends_on, &Map.has_key?(succeeded, &1))

  defp context_for(plan, succeeded) do
    Enum.flat_map(plan.depends_on, fn id ->
      case Map.get(succeeded, id) do
        %Result{summary: s} -> ["[#{id}] #{s}"]
        _ -> []
      end
    end)
  end

  # ---- running one plan (with a single retry on error) ----

  defp run_plan(plan, context, timeout, attempt \\ 0) do
    result = run_agent(plan, context, timeout)

    if result.status == :error and attempt < 1 do
      Logger.info("retrying plan #{plan.id} after error")
      run_plan(plan, context, timeout, attempt + 1)
    else
      result
    end
  end

  defp run_agent(plan, context, timeout) do
    ref = make_ref()

    spec = {Agent, %{ref: ref, plan: plan.description, orchestrator: self(), context: context}}

    case DynamicSupervisor.start_child(NanoAgent.AgentSupervisor, spec) do
      {:ok, pid} -> await_agent(pid, timeout)
      {:error, reason} -> %Result{status: :error, summary: "agent not started", error: reason}
    end
  end

  defp await_agent(pid, timeout) do
    mref = Process.monitor(pid)

    receive do
      {:agent_done, ^pid, %Result{} = result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, reason} ->
        %Result{status: :error, summary: "agent crashed", error: reason}
    after
      timeout ->
        Process.demonitor(mref, [:flush])
        DynamicSupervisor.terminate_child(NanoAgent.AgentSupervisor, pid)
        %Result{status: :error, summary: "agent timed out", error: :timeout}
    end
  end

  # ---- aggregation ----

  defp build_report(goal, outcomes, planner_tokens) do
    statuses = Enum.map(outcomes, & &1.result.status)

    status =
      cond do
        Enum.all?(statuses, &(&1 == :ok)) -> :ok
        Enum.any?(statuses, &(&1 == :ok)) -> :partial
        true -> :failed
      end

    # Include the planner's own decomposition call in the token accounting.
    tokens =
      Enum.reduce(outcomes, planner_tokens, fn %{result: r}, acc ->
        %{input: acc.input + r.tokens.input, output: acc.output + r.tokens.output}
      end)

    %GoalReport{goal: goal, status: status, outcomes: outcomes, tokens: tokens}
  end

  defp blocked_result do
    %Result{status: :error, summary: "skipped: a dependency failed", error: :blocked}
  end
end
