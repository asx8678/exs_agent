defmodule NanoAgent.M4Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Store, Resume, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "a completed run is persisted with status :ok" do
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("all done")])
    assert {:ok, _result} = NanoAgent.run("do a thing", 5_000)

    runs = Store.list()
    assert Enum.any?(runs, &(&1.status == :ok and &1.summary =~ "all done"))
  end

  test "checkpointing persists message history mid-run" do
    Application.put_env(:nano_agent, :mock, [
      Mock.tool_use("t1", "bash", %{"command" => "echo hi"}),
      Mock.end_turn("finished")
    ])

    {:ok, _} = NanoAgent.run("run a command", 5_000)
    run = Store.list() |> Enum.find(&(&1.summary =~ "finished"))
    assert run.tool_calls == 1
    # message history was recorded (user, assistant, tool_result, ...)
    assert length(run.messages) >= 3
  end

  test "an interrupted run is resumed from its saved state" do
    # Simulate a crash: a :running record with a saved message history.
    Store.register("r1", "resume me")

    Store.checkpoint("r1", %{
      messages: [%{role: "user", content: "resume me"}],
      iterations: 0
    })

    assert [%{status: :running}] = Store.running()

    Application.put_env(:nano_agent, :mock, [Mock.end_turn("resumed and finished")])

    assert [{"r1", result}] = Resume.resume_all()
    assert result.status == :ok

    run = Store.get("r1")
    assert run.status == :ok
    assert run.summary =~ "resumed and finished"
    assert Store.running() == []
  end
end
