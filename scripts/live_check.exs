# Live end-to-end validation against the real provider APIs.
# Run with a key available, e.g.:
#   set -a; . ./.env; set +a; NANO_WEB_DISABLED=1 mix run scripts/live_check.exs
#
# Operates inside a throwaway temp dir so the agent's file/bash tools don't touch
# the repo.

defmodule LiveCheck do
  def run do
    tmp = Path.join(System.tmp_dir!(), "nano_live_#{System.system_time(:second)}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)
    IO.puts("workdir: #{tmp}\n")

    IO.puts("provider: #{inspect(Application.get_env(:nano_agent, :provider))}\n")
    single_plan()
    goal()

    IO.puts("\n✅ live check complete — workdir: #{tmp}")
  end

  defp single_plan do
    banner("single plan (configured provider)")

    NanoAgent.run("""
    Use the bash tool to create a file hello.txt containing exactly 'hi from nano',
    then read it back with the read tool and report its contents.
    """)
    |> print_result()
  end

  defp goal do
    banner("goal (decomposition + dependency fan-out)")

    NanoAgent.run_goal("""
    Create a.txt containing 'one' and b.txt containing 'two'. Then create
    combined.txt containing both lines in order, and verify combined.txt's contents.
    """)
    |> case do
      {:ok, report} ->
        IO.puts("goal status=#{report.status}  tokens=#{inspect(report.tokens)}")

        for %{plan: p, result: r} <- report.outcomes do
          IO.puts("  [#{r.status}] #{p.id} (#{r.tool_calls} tools): #{String.slice(r.summary, 0, 90)}")
        end

      other ->
        IO.inspect(other, label: "goal failed")
    end
  end

  defp print_result({:ok, r}) do
    IO.puts("status=#{r.status}  tools=#{r.tool_calls}  tokens=#{inspect(r.tokens)}")
    IO.puts(r.summary)
  end

  defp print_result(other), do: IO.inspect(other, label: "failed")

  defp banner(t), do: IO.puts("\n== #{t} ==")
end

LiveCheck.run()
