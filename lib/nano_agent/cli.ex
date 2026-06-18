defmodule NanoAgent.CLI do
  @moduledoc """
  Command-line entrypoint (also the escript `main_module`).

      nano_agent [options] "goal or plan text"

  Options:
    --plan            Treat the text as a single plan (skip goal decomposition)
    --json            Stream events as NDJSON (one JSON object per line)
    --dir DIR         Confine filesystem tools to DIR (enables the sandbox)
    --model MODEL     Override the model
    --concurrency N   Max concurrent agents for a goal (default 5)

  `run/1` does the work and returns `{:ok, _} | {:error, _}` (used by tests).
  `main/1` wraps it with `System.halt` for the escript.
  """
  alias NanoAgent.{Events, Web}

  @switches [plan: :boolean, json: :boolean, dir: :string, model: :string, concurrency: :integer]
  @aliases [j: :json, p: :plan]

  def main(argv) do
    case run(argv) do
      {:ok, _} -> System.halt(0)
      _ -> System.halt(1)
    end
  end

  def run(argv) do
    {opts, rest, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)
    text = Enum.join(rest, " ")

    if text == "" do
      IO.puts(:stderr, @moduledoc)
      {:error, :no_input}
    else
      {:ok, _} = Application.ensure_all_started(:nano_agent)
      if opts[:dir], do: configure_sandbox(opts[:dir])
      execute(text, opts)
    end
  end

  defp execute(text, opts) do
    Events.subscribe(:all)
    caller = self()

    Task.start(fn ->
      outcome =
        if opts[:plan] do
          {:plan, NanoAgent.run(text)}
        else
          {:goal, NanoAgent.run_goal(text, run_opts(opts))}
        end

      send(caller, {:final, outcome})
    end)

    drain(opts[:json] || false)
  end

  defp drain(json?) do
    receive do
      {:nano_event, e} ->
        IO.puts(format_event(e, json?))
        drain(json?)

      {:final, outcome} ->
        print_final(outcome, json?)
        status(outcome)
    end
  end

  # ---- formatting ----

  defp format_event(e, true), do: Web.encode_event(e)

  defp format_event(e, false) do
    p = e.payload
    detail = p[:name] || p[:summary] || ""
    "  • #{e.type} #{detail}"
  end

  defp print_final({:plan, {:ok, r}}, true), do: IO.puts(result_json(r))
  defp print_final({:plan, {:ok, r}}, false), do: IO.puts("\n[#{r.status}] #{r.summary}")
  defp print_final({:plan, other}, _), do: IO.puts("\n#{inspect(other)}")

  defp print_final({:goal, {:ok, report}}, true) do
    IO.puts(report_json(report))
  end

  defp print_final({:goal, {:ok, report}}, false) do
    IO.puts(
      "\n=== goal: #{report.status} (#{length(report.outcomes)} plans, #{report.tokens.output} out tokens) ==="
    )

    for %{plan: plan, result: r} <- report.outcomes do
      IO.puts("  [#{r.status}] #{plan.id}: #{String.slice(r.summary, 0, 100)}")
    end
  end

  defp print_final({:goal, {:error, reason}}, _),
    do: IO.puts("\nplanning failed: #{inspect(reason)}")

  defp status({_, {:ok, _}}), do: {:ok, :done}
  defp status(other), do: {:error, other}

  defp result_json(r) do
    %{
      "status" => to_string(r.status),
      "summary" => r.summary,
      "tokens" => r.tokens,
      "tool_calls" => r.tool_calls
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp report_json(report) do
    %{
      "goal" => report.goal,
      "status" => to_string(report.status),
      "tokens" => report.tokens,
      "outcomes" =>
        Enum.map(report.outcomes, fn %{plan: p, result: r} ->
          %{"id" => p.id, "status" => to_string(r.status), "summary" => r.summary}
        end)
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  # ---- options ----

  defp run_opts(opts) do
    []
    |> put_opt(:max_concurrency, opts[:concurrency])
    |> put_opt(:model, opts[:model])
  end

  defp put_opt(kw, _key, nil), do: kw
  defp put_opt(kw, key, val), do: Keyword.put(kw, key, val)

  defp configure_sandbox(dir) do
    Application.put_env(:nano_agent, :sandbox, root: Path.expand(dir), enforce: true)
  end
end
