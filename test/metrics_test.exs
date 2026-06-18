defmodule NanoAgent.MetricsTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Metrics, Store, Web, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "snapshot aggregates counts, tokens, and duration percentiles" do
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("done")])
    assert {:ok, _} = NanoAgent.run("task one", 5_000)
    assert {:ok, _} = NanoAgent.run("task two", 5_000)

    m = Metrics.snapshot()
    assert m.total == 2
    assert m.by_status[:ok] == 2
    assert m.tokens.output > 0
    assert m.duration_ms.count == 2
    assert is_integer(m.duration_ms.p50)
  end

  test "metrics are served as JSON over HTTP" do
    start_supervised!({Web, port: 0})

    {:ok, {{_, 200, _}, _h, body}} =
      :httpc.request(:get, {~c"http://127.0.0.1:#{Web.port()}/api/metrics", []}, [],
        body_format: :binary
      )

    decoded = :json.decode(body)
    assert Map.has_key?(decoded, "total")
    assert Map.has_key?(decoded, "tokens")
    assert get_in(decoded, ["duration_ms", "p95"]) != nil
  end
end
