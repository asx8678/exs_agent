defmodule NanoAgent.CLI do
  @moduledoc """
  Command-line entrypoint (also the escript `main_module`).

      nano_agent [options] "goal or plan text"   # run a goal (or --plan)
      nano_agent history [--json]                # list past runs
      nano_agent export <run-id> [--json]        # print a run as Markdown or JSON
      nano_agent doctor                          # check provider/key/model connectivity

  Options:
    --plan            Treat the text as a single plan (skip goal decomposition)
    --json            Stream events as NDJSON; or JSON output for history/export
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

    case rest do
      ["history" | _] ->
        started!()
        cmd_history(opts)

      ["export", id | _] ->
        started!()
        cmd_export(id, opts)

      ["doctor" | _] ->
        started!()
        cmd_doctor()

      [] ->
        IO.puts(:stderr, @moduledoc)
        {:error, :no_input}

      words ->
        started!()
        if opts[:dir], do: configure_sandbox(opts[:dir])
        execute(Enum.join(words, " "), opts)
    end
  end

  defp started!, do: {:ok, _} = Application.ensure_all_started(:nano_agent)

  defp cmd_history(opts) do
    runs = NanoAgent.history()

    if opts[:json] do
      runs
      |> Enum.map(fn r -> Map.take(r, [:id, :status, :summary, :tool_calls]) |> stringify() end)
      |> then(&IO.puts(:json.encode(&1) |> IO.iodata_to_binary()))
    else
      if runs == [], do: IO.puts("(no runs)")

      for r <- runs do
        IO.puts("#{r.id}  [#{r.status}]  #{String.slice(r.summary, 0, 70)}")
      end
    end

    {:ok, :done}
  end

  defp cmd_export(id, opts) do
    format = if opts[:json], do: :json, else: :markdown

    case NanoAgent.export(id, format) do
      {:ok, body} ->
        IO.puts(body)
        {:ok, :done}

      {:error, :not_found} ->
        IO.puts(:stderr, "run not found: #{id}")
        {:error, :not_found}
    end
  end

  defp cmd_doctor do
    provider = Application.get_env(:nano_agent, :provider)
    env = key_env(provider)
    key_status = if env && System.get_env(env), do: "present", else: "MISSING"

    IO.puts("provider:  #{inspect(provider)}")
    IO.puts("key (#{env || "n/a"}):  #{key_status}")

    case NanoAgent.Config.validate() do
      [] -> IO.puts("config:    ok")
      issues -> Enum.each(issues, &IO.puts("config:    ⚠ #{&1}"))
    end

    IO.puts("probing with a minimal request...\n")

    case NanoAgent.run("Reply with exactly the single word: ok") do
      {:ok, r} ->
        IO.puts("status:  #{r.status}")
        IO.puts("tokens:  in #{r.tokens.input} / out #{r.tokens.output}")
        IO.puts("reply:   #{String.slice(r.summary, 0, 120)}")
        if r.status == :ok, do: {:ok, :done}, else: {:error, r.status}

      other ->
        IO.inspect(other, label: "probe failed")
        {:error, :probe}
    end
  end

  defp key_env(NanoAgent.Provider.DeepSeek), do: "DEEPSEEK_API_KEY"
  defp key_env(NanoAgent.Provider.OpenAI), do: "OPENAI_API_KEY"
  defp key_env(NanoAgent.Provider.Anthropic), do: "ANTHROPIC_API_KEY"
  defp key_env(NanoAgent.Provider.AnthropicStream), do: "ANTHROPIC_API_KEY"
  defp key_env(_), do: nil

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), to_jsonable(v)} end)
  defp to_jsonable(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp to_jsonable(v), do: v

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
