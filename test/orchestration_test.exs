defmodule NanoAgent.OrchestrationTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Web, Events, Store, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  defp planner_then_agents(plans) do
    fn _m, tools, _o ->
      if Enum.any?(tools, &(&1[:name] == "submit_plan")) do
        {:ok, Mock.tool_use("p", "submit_plan", %{"plans" => plans})}
      else
        {:ok, Mock.end_turn("done")}
      end
    end
  end

  test "a goal's agents carry the goal_id (so the dashboard can group them)" do
    Events.subscribe(:all)

    Application.put_env(
      :nano_agent,
      :mock,
      planner_then_agents([
        %{"id" => "a", "description" => "do a", "depends_on" => []},
        %{"id" => "b", "description" => "do b", "depends_on" => []}
      ])
    )

    {:ok, _report} = NanoAgent.run_goal("two things", goal_id: "G123")

    # the :planned event names the goal and its plans
    assert_receive {:nano_event, %{type: :planned, payload: %{goal_id: "G123", plans: plans}}},
                   1000

    assert length(plans) == 2

    # each agent's started event carries the goal_id
    assert_receive {:nano_event, %{type: :started, payload: %{goal_id: "G123"}}}, 1000
  end

  test "POST /runs with a goal returns a goal_id" do
    Application.put_env(
      :nano_agent,
      :mock,
      planner_then_agents([%{"id" => "1", "description" => "x", "depends_on" => []}])
    )

    start_supervised!({Web, port: 0})

    {:ok, {{_, 202, _}, _h, body}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{Web.port()}/runs", [], ~c"application/json",
         ~s({"goal":"do stuff"})},
        [],
        body_format: :binary
      )

    assert %{"goal_id" => gid, "status" => "started"} = :json.decode(body)
    assert is_binary(gid)
  end

  test "dashboard page includes the dispatch bar and cancel/goal wiring" do
    start_supervised!({Web, port: 0})

    {:ok, {{_, 200, _}, _h, html}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{Web.port()}/", []}, [], body_format: :binary)

    assert html =~ ~s(id="cmd")
    assert html =~ "Run goal"
    assert html =~ "function dispatch"
    assert html =~ "function cancelRun"
    assert html =~ "function cancelGoal"
    assert html =~ "goalMeta"
    assert html =~ "gdag"
    assert html =~ "goal "
  end

  test "a goal with a dependent plan: the dependent's agent carries the goal_id too" do
    Events.subscribe(:all)

    Application.put_env(
      :nano_agent,
      :mock,
      planner_then_agents([
        %{"id" => "a", "description" => "do a", "depends_on" => []},
        %{"id" => "b", "description" => "do b after a", "depends_on" => ["a"]}
      ])
    )

    {:ok, _} = NanoAgent.run_goal("pipeline", goal_id: "GP")

    # both the independent and the dependent plan's agents report under the goal
    assert_receive {:nano_event, %{type: :ok, payload: %{goal_id: "GP"}}}, 2000
    assert_receive {:nano_event, %{type: :ok, payload: %{goal_id: "GP"}}}, 2000
  end

  test "goal-level events don't create a spurious run in the tracker rollup" do
    Application.put_env(
      :nano_agent,
      :mock,
      planner_then_agents([%{"id" => "1", "description" => "x", "depends_on" => []}])
    )

    {:ok, _} = NanoAgent.run_goal("g", goal_id: "GX")
    # let the tracker process the events
    _ = NanoAgent.Tracker.events()

    refute Map.has_key?(NanoAgent.Tracker.runs(), inspect(:goal))
  end
end
