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
      {:ok, plans} ->
        Logger.info("planned #{length(plans)} sub-plan(s) for goal")
        Events.publish(:goal, :planned, %{count: length(plans)})
        {:ok, schedule(goal, plans, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ---- scheduler ----

  defp schedule(goal, plans, opts) do
    cap = opts[:max_concurrency] || Application.get_env(:nano_agent, :max_concurrency, 5)
    timeout = opts[:agent_timeout] || @agent_timeout

    outcomes =
      loop(%{pending: plans, succeeded: %{}, outcomes: []}, cap, timeout).outcomes

    build_report(goal, outcomes)
  end

  defp loop(%{pending: []} = state, _cap, _timeout), do: state

  defp loop(state, cap, timeout) do
    {ready, rest} = Enum.split_with(state.pending, &ready?(&1, state.succeeded))

    if ready == [] do
      # Nothing runnable but plans remain -> blocked by failed deps (or a cycle).
      skipped =
        Enum.map(rest, fn p ->
          %{plan: p, result: blocked_result()}
        end)

      %{state | pending: [], outcomes: state.outcomes ++ skipped}
    else
      results =
        Task.Supervisor.async_stream_nolink(
          NanoAgent.TaskSupervisor,
          ready,
          fn plan -> {plan, run_plan(plan, context_for(plan, state.succeeded), timeout)} end,
          max_concurrency: cap,
          timeout: timeout + 30_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, pair} -> pair
          {:exit, _reason} -> nil
        end)
        |> Enum.reject(&is_nil/1)

      succeeded =
        Enum.reduce(results, state.succeeded, fn {plan, result}, acc ->
          if result.status == :ok, do: Map.put(acc, plan.id, result), else: acc
        end)

      outcomes = state.outcomes ++ Enum.map(results, fn {plan, r} -> %{plan: plan, result: r} end)

      loop(%{state | pending: rest, succeeded: succeeded, outcomes: outcomes}, cap, timeout)
    end
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

    {:ok, pid} =
      DynamicSupervisor.start_child(
        NanoAgent.AgentSupervisor,
        {Agent, %{ref: ref, plan: plan.description, orchestrator: self(), context: context}}
      )

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

  defp build_report(goal, outcomes) do
    statuses = Enum.map(outcomes, & &1.result.status)

    status =
      cond do
        Enum.all?(statuses, &(&1 == :ok)) -> :ok
        Enum.any?(statuses, &(&1 == :ok)) -> :partial
        true -> :failed
      end

    tokens =
      Enum.reduce(outcomes, %{input: 0, output: 0}, fn %{result: r}, acc ->
        %{input: acc.input + r.tokens.input, output: acc.output + r.tokens.output}
      end)

    %GoalReport{goal: goal, status: status, outcomes: outcomes, tokens: tokens}
  end

  defp blocked_result do
    %Result{status: :error, summary: "skipped: a dependency failed", error: :blocked}
  end
end
