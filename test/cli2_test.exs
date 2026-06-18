defmodule NanoAgent.CLI2Test do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias NanoAgent.{Store, CLI, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  defp seed_run do
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("seeded summary")])
    {:ok, _} = NanoAgent.run("seed a run", 5_000)
    Store.list() |> hd() |> Map.get(:id)
  end

  test "history lists runs" do
    id = seed_run()
    out = capture_io(fn -> assert {:ok, _} = CLI.run(["history"]) end)
    assert out =~ id
    assert out =~ "seeded summary"
  end

  test "history --json emits a JSON array" do
    seed_run()
    out = capture_io(fn -> assert {:ok, _} = CLI.run(["history", "--json"]) end)
    assert [%{"status" => "ok"} | _] = :json.decode(String.trim(out))
  end

  test "export prints a run as markdown" do
    id = seed_run()
    out = capture_io(fn -> assert {:ok, _} = CLI.run(["export", id]) end)
    assert out =~ "# Run #{id}"
    assert out =~ "seeded summary"
  end

  test "export of an unknown id reports not found" do
    capture_io(:stderr, fn ->
      assert {:error, :not_found} = CLI.run(["export", "does-not-exist"])
    end)
  end
end
