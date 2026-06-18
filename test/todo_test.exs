defmodule NanoAgent.TodoTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Store, Events, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "todo_write records progress, emits an event, and persists to the run" do
    Events.subscribe(:all)

    items = [
      %{"content" => "read the file", "status" => "completed"},
      %{"content" => "edit the file", "status" => "in_progress"},
      %{"content" => "run tests", "status" => "pending"}
    ]

    Application.put_env(:nano_agent, :mock, [
      Mock.tool_use("td", "todo_write", %{"items" => items}),
      Mock.end_turn("all set")
    ])

    assert {:ok, r} = NanoAgent.run("do a multi-step task", 5_000)
    assert r.status == :ok
    # todo_write is bookkeeping — it should not count as a real tool call
    assert r.tool_calls == 0

    assert_receive {:nano_event, %{type: :todos, payload: %{items: ^items}}}, 1000

    run = Store.list() |> Enum.find(&(&1.summary =~ "all set"))
    assert run.todos == items
  end
end
