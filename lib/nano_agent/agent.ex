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

  alias NanoAgent.{LLM, Tools, Result, Events, Store, Safety, Approvals}

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

  defp run_loop(%{iterations: n} = state) when n >= @max_iterations do
    result(state, :max_iterations)
  end

  defp run_loop(state) do
    case LLM.chat(state.messages, Tools.specs()) do
      {:ok, %{"content" => content} = resp} ->
        state =
          state
          |> add_usage(resp["usage"])
          |> Map.put(:last_text, extract_text(content))

        tool_uses = Enum.filter(content, &(&1["type"] == "tool_use"))

        if resp["stop_reason"] == "tool_use" and tool_uses != [] do
          results = Enum.map(tool_uses, &run_tool(&1, state.ref))

          messages =
            state.messages ++
              [%{role: "assistant", content: content}, %{role: "user", content: results}]

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

  defp run_tool(%{"id" => id, "name" => name, "input" => input}, ref) do
    Events.publish(ref, :tool_call, %{name: name, input: input})

    output =
      case gate(ref, name, input) do
        :approved -> Tools.run(name, input)
        :denied -> "error: tool '#{name}' denied by approval policy"
      end

    Events.publish(ref, :tool_result, %{name: name, output_preview: String.slice(output, 0, 200)})
    %{"type" => "tool_result", "tool_use_id" => id, "content" => output}
  end

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
