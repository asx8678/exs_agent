defmodule NanoAgent.Agent do
  @moduledoc """
  An ephemeral worker process. Receives a plan (or a resumed message history),
  runs an LLM tool-use loop until the model stops requesting tools, persists
  progress to `NanoAgent.Store` after every iteration, reports a
  `%NanoAgent.Result{}` to the orchestrator, and terminates normally.

  `restart: :temporary` — a finished or crashed agent is never auto-restarted;
  the orchestrator's monitor decides what to do. State lives entirely inside this
  process, so agents are fully isolated from one another.
  """
  use GenServer, restart: :temporary
  require Logger

  alias NanoAgent.{LLM, Tools, Result, Events, Store, Safety, Approvals, Context}

  @max_iterations 25

  def start_link(%{ref: _} = args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init(args) do
    ref = Map.fetch!(args, :ref)
    orch = Map.fetch!(args, :orchestrator)
    run_id = Map.get(args, :run_id) || gen_id()
    plan = Map.get(args, :plan, "")
    context = Map.get(args, :context, [])
    resuming? = Map.has_key?(args, :messages)
    messages = Map.get(args, :messages) || [%{role: "user", content: build_prompt(plan, context)}]

    unless resuming?, do: Store.register(run_id, plan)

    state = %{
      ref: ref,
      orchestrator: orch,
      run_id: run_id,
      plan: plan,
      messages: messages,
      iterations: Map.get(args, :iterations, 0),
      tool_calls: Map.get(args, :tool_calls, 0),
      tokens: Map.get(args, :tokens, %{input: 0, output: 0}),
      last_text: "",
      depth: Map.get(args, :depth, 0),
      started_at: System.monotonic_time(:millisecond)
    }

    {:ok, state, {:continue, :work}}
  end

  @impl true
  def handle_continue(:work, state) do
    Events.publish(state.ref, :started, %{plan: state.plan, run_id: state.run_id})
    result = run_loop(state)
    Store.finish(state.run_id, result)
    duration = System.monotonic_time(:millisecond) - state.started_at

    Events.publish(state.ref, result.status, %{
      run_id: state.run_id,
      summary: result.summary,
      duration_ms: duration,
      tool_calls: result.tool_calls,
      tokens: result.tokens
    })

    send(state.orchestrator, {:agent_done, self(), result})
    {:stop, :normal, state}
  end

  # ---- the tool-use loop ----

  defp run_loop(state) do
    cond do
      state.iterations >= @max_iterations -> result(state, :max_iterations)
      over_budget?(state) -> result(state, :budget)
      true -> do_step(state)
    end
  end

  defp over_budget?(state) do
    case Application.get_env(:nano_agent, :max_run_tokens, :infinity) do
      :infinity -> false
      max -> state.tokens.input + state.tokens.output >= max
    end
  end

  defp do_step(state) do
    case LLM.chat(state.messages, tool_specs(state)) do
      {:ok, %{"content" => content} = resp} ->
        state =
          state
          |> add_usage(resp["usage"])
          |> Map.put(:last_text, extract_text(content))

        tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

        if resp["stop_reason"] == "tool_use" and tool_uses != [] do
          results = Enum.map(tool_uses, &run_tool(&1, state))

          messages =
            (state.messages ++
               [%{role: "assistant", content: content}, %{role: "user", content: results}])
            |> Context.compact()

          state = %{
            state
            | messages: messages,
              iterations: state.iterations + 1,
              tool_calls: state.tool_calls + length(tool_uses)
          }

          checkpoint(state)
          run_loop(state)
        else
          result(state, :ok)
        end

      {:error, reason} ->
        %{result(state, :error) | error: reason, summary: "agent failed: #{inspect(reason)}"}
    end
  end

  defp run_tool(%{"id" => id, "name" => name, "input" => input}, state) do
    ref = state.ref
    Events.publish(ref, :tool_call, %{name: name, input: input})

    output =
      cond do
        name == "spawn_agent" -> spawn_child_tool(input, state)
        true -> guarded(ref, name, input)
      end

    Events.publish(ref, :tool_result, %{name: name, output_preview: String.slice(output, 0, 200)})
    %{"type" => "tool_result", "tool_use_id" => id, "content" => output}
  end

  defp guarded(ref, name, input) do
    case gate(ref, name, input) do
      :approved -> Tools.run(name, input)
      :denied -> "error: tool '#{name}' denied by approval policy"
    end
  end

  # ---- subagents ----

  defp tool_specs(state), do: Tools.specs() ++ subagent_specs(state.depth)

  defp subagent_specs(depth) do
    if Application.get_env(:nano_agent, :subagents_enabled, false) and depth < max_depth() do
      [
        %{
          name: "spawn_agent",
          description:
            "Delegate a self-contained sub-task to a child agent and get its result summary. " <>
              "Use for independent chunks of work you want handled separately.",
          input_schema: %{
            type: "object",
            properties: %{
              plan: %{type: "string", description: "Self-contained instruction for the child"}
            },
            required: ["plan"]
          }
        }
      ]
    else
      []
    end
  end

  defp spawn_child_tool(input, state) do
    plan = input["plan"] || input["goal"] || ""

    cond do
      not Application.get_env(:nano_agent, :subagents_enabled, false) ->
        "error: subagents are disabled"

      state.depth >= max_depth() ->
        "error: max subagent depth (#{max_depth()}) reached"

      plan == "" ->
        "error: spawn_agent requires a non-empty plan"

      true ->
        r = run_child(plan, state.depth + 1)
        "[subagent #{r.status}] #{r.summary}"
    end
  end

  defp run_child(plan, depth) do
    ref = make_ref()
    spec = {__MODULE__, %{ref: ref, plan: plan, orchestrator: self(), depth: depth}}

    case DynamicSupervisor.start_child(NanoAgent.AgentSupervisor, spec) do
      {:ok, pid} -> await_child(pid, 180_000)
      {:error, reason} -> %Result{status: :error, summary: "child not started", error: reason}
    end
  end

  defp await_child(pid, timeout) do
    mref = Process.monitor(pid)

    receive do
      {:agent_done, ^pid, %Result{} = result} ->
        Process.demonitor(mref, [:flush])
        result

      {:DOWN, ^mref, :process, ^pid, reason} ->
        %Result{status: :error, summary: "child crashed", error: reason}
    after
      timeout ->
        Process.demonitor(mref, [:flush])
        DynamicSupervisor.terminate_child(NanoAgent.AgentSupervisor, pid)
        %Result{status: :error, summary: "child timed out", error: :timeout}
    end
  end

  defp max_depth, do: Application.get_env(:nano_agent, :max_subagent_depth, 2)

  defp gate(ref, name, input) do
    if Safety.requires_approval?(name, input) do
      Approvals.request(%{ref: ref, name: name, input: input})
    else
      :approved
    end
  end

  # ---- helpers ----

  defp result(state, status) do
    %Result{
      status: status,
      summary: state.last_text,
      iterations: state.iterations,
      tool_calls: state.tool_calls,
      tokens: state.tokens
    }
  end

  defp checkpoint(state) do
    Store.checkpoint(state.run_id, %{
      messages: state.messages,
      iterations: state.iterations,
      tool_calls: state.tool_calls,
      tokens: state.tokens
    })
  end

  defp build_prompt(plan, []), do: plan

  defp build_prompt(plan, context) do
    notes = Enum.map_join(context, "\n", fn c -> "- #{c}" end)
    "Context from earlier steps:\n#{notes}\n\nYour plan:\n#{plan}"
  end

  defp add_usage(state, %{"input_tokens" => i, "output_tokens" => o}) do
    %{state | tokens: %{input: state.tokens.input + i, output: state.tokens.output + o}}
  end

  defp add_usage(state, _), do: state

  defp extract_text(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
