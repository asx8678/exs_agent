defmodule NanoAgent.M7Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Provider.Mock, Orchestrator}

  setup do
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "transient provider errors are retried, then succeed" do
    ctr = :counters.new(1, [:atomics])

    Application.put_env(:nano_agent, :mock, fn _m, _t, _o ->
      n = :counters.get(ctr, 1)
      :counters.add(ctr, 1, 1)
      if n < 2, do: {:error, {:http, 503, "busy"}}, else: {:ok, Mock.end_turn("recovered")}
    end)

    assert {:ok, r} = NanoAgent.run("flaky", 5_000)
    assert r.status == :ok
    assert r.summary =~ "recovered"
    assert :counters.get(ctr, 1) == 3
  end

  test "non-retryable errors are not retried" do
    ctr = :counters.new(1, [:atomics])

    Application.put_env(:nano_agent, :mock, fn _m, _t, _o ->
      :counters.add(ctr, 1, 1)
      {:error, :unauthorized}
    end)

    assert {:ok, %{status: :error}} = NanoAgent.run("bad", 5_000)
    assert :counters.get(ctr, 1) == 1
  end

  test "a crashing agent does not take down the supervision tree" do
    orch = Process.whereis(Orchestrator)
    assert is_pid(orch) and Process.alive?(orch)

    Application.put_env(:nano_agent, :mock, fn _m, _t, _o -> raise "boom" end)
    assert {:failed, _reason} = NanoAgent.run("crash me", 5_000)

    # Orchestrator + supervisor survived...
    assert Process.alive?(orch)
    assert Process.whereis(NanoAgent.AgentSupervisor) |> Process.alive?()

    # ...and the system still works afterwards.
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("still alive")])
    assert {:ok, r} = NanoAgent.run("again", 5_000)
    assert r.summary =~ "still alive"
  end
end
