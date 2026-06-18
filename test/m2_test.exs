defmodule NanoAgent.M2Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{GoalReport, Provider.Mock}

  setup do
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  defp last_user_text(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: "user", content: c} when is_binary(c) -> c
      _ -> nil
    end)
  end

  # A mock that plays the planner role when offered submit_plan, and otherwise
  # acts as an execution agent that finishes immediately.
  defp planner_then_agents(plans) do
    fn _messages, tools, _opts ->
      if Enum.any?(tools, &(&1[:name] == "submit_plan")) do
        {:ok, Mock.tool_use("p", "submit_plan", %{"plans" => plans})}
      else
        {:ok, Mock.end_turn("completed")}
      end
    end
  end

  test "decomposes a goal and runs independent plans" do
    Application.put_env(
      :nano_agent,
      :mock,
      planner_then_agents([
        %{"id" => "a", "description" => "do A", "depends_on" => []},
        %{"id" => "b", "description" => "do B", "depends_on" => []}
      ])
    )

    assert {:ok, %GoalReport{status: :ok, outcomes: outcomes}} =
             NanoAgent.run_goal("two independent things")

    assert length(outcomes) == 2
    assert Enum.all?(outcomes, &(&1.result.status == :ok))
  end

  test "respects dependencies and threads upstream context downstream" do
    # Agent for "b" should receive "a"'s summary in its prompt context.
    mock = fn messages, tools, _opts ->
      cond do
        Enum.any?(tools, &(&1[:name] == "submit_plan")) ->
          {:ok,
           Mock.tool_use("p", "submit_plan", %{
             "plans" => [
               %{"id" => "a", "description" => "produce A", "depends_on" => []},
               %{"id" => "b", "description" => "use A", "depends_on" => ["a"]}
             ]
           })}

        String.contains?(last_user_text(messages), "Context from earlier steps") ->
          {:ok, Mock.end_turn("b saw upstream context")}

        true ->
          {:ok, Mock.end_turn("A produced")}
      end
    end

    Application.put_env(:nano_agent, :mock, mock)

    assert {:ok, %GoalReport{status: :ok, outcomes: outcomes}} =
             NanoAgent.run_goal("dependent pipeline")

    assert length(outcomes) == 2
    b = Enum.find(outcomes, &(&1.plan.id == "b"))
    assert b.result.summary =~ "upstream context"
  end

  test "skips plans whose dependency failed" do
    mock = fn messages, tools, _opts ->
      cond do
        Enum.any?(tools, &(&1[:name] == "submit_plan")) ->
          {:ok,
           Mock.tool_use("p", "submit_plan", %{
             "plans" => [
               %{"id" => "a", "description" => "fails", "depends_on" => []},
               %{"id" => "b", "description" => "needs a", "depends_on" => ["a"]}
             ]
           })}

        String.contains?(last_user_text(messages), "fails") ->
          {:error, :boom}

        true ->
          {:ok, Mock.end_turn("ok")}
      end
    end

    Application.put_env(:nano_agent, :mock, mock)

    assert {:ok, %GoalReport{status: status, outcomes: outcomes}} =
             NanoAgent.run_goal("one fails")

    assert status in [:failed, :partial]
    b = Enum.find(outcomes, &(&1.plan.id == "b"))
    assert b.result.error == :blocked
  end
end
