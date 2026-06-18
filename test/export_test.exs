defmodule NanoAgent.ExportTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Store, Web, Export, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  defp run_one do
    Application.put_env(:nano_agent, :mock, [
      Mock.tool_use("t1", "bash", %{"command" => "echo hi"}),
      Mock.end_turn("finished the task")
    ])

    {:ok, _} = NanoAgent.run("do the thing", 5_000)
    Store.list() |> hd() |> Map.get(:id)
  end

  test "markdown export includes plan, tool call, and summary" do
    id = run_one()
    {:ok, md} = Export.markdown(id)

    assert md =~ "# Run #{id}"
    assert md =~ "## Plan"
    assert md =~ "do the thing"
    assert md =~ "→ bash"
    assert md =~ "finished the task"
  end

  test "json export round-trips through the JSON decoder" do
    id = run_one()
    {:ok, json} = Export.json(id)
    decoded = :json.decode(json)
    assert decoded["id"] == id
    assert decoded["status"] == "ok"
    assert is_list(decoded["messages"])
  end

  test "export is served over HTTP in both formats" do
    id = run_one()
    start_supervised!({Web, port: 0})
    base = ~c"http://127.0.0.1:#{Web.port()}/runs/" ++ String.to_charlist(id)

    {:ok, {{_, 200, _}, h, md}} =
      :httpc.request(:get, {base ++ ~c"/export.md", []}, [], body_format: :binary)

    assert md =~ "# Run"
    assert {~c"content-type", ~c"text/markdown; charset=utf-8"} in h

    {:ok, {{_, 200, _}, _h, json}} =
      :httpc.request(:get, {base ++ ~c"/export.json", []}, [], body_format: :binary)

    assert :json.decode(json)["id"] == id

    {:ok, {{_, 404, _}, _, _}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{Web.port()}/runs/nope/export.md", []}, [],
        body_format: :binary
      )
  end
end
