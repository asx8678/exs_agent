defmodule NanoAgent.M3Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Events, Tracker, Web}

  test "events flow through the bus to subscribers" do
    Events.subscribe(:all)
    ref = make_ref()
    Events.publish(ref, :tool_call, %{name: "bash", input: %{"command" => "ls"}})

    assert_receive {:nano_event, %{ref: ^ref, type: :tool_call, payload: %{name: "bash"}}}, 1000
  end

  test "tracker rolls up events into per-run state" do
    ref = make_ref()
    Events.publish(ref, :started, %{plan: "p"})
    Events.publish(ref, :tool_call, %{name: "bash"})
    Events.publish(ref, :ok, %{summary: "done"})
    # let the Tracker GenServer process the casts
    _ = Tracker.events()

    runs = Tracker.runs()
    run = runs[inspect(ref)]
    assert run.status == :ok
    assert run.tool_calls == 1
  end

  test "web server serves the dashboard and a JSON snapshot, and streams SSE" do
    start_supervised!({Web, port: 0})
    port = Web.port()
    base = ~c"http://127.0.0.1:#{port}"

    {:ok, {{_, 200, _}, _h, html}} =
      :httpc.request(:get, {base ++ ~c"/", []}, [], body_format: :binary)

    assert html =~ "nano_agent fleet"

    {:ok, {{_, 200, _}, _h, json}} =
      :httpc.request(:get, {base ++ ~c"/api/events", []}, [], body_format: :binary)

    assert is_list(:json.decode(json))

    # SSE: connect raw, publish an event, expect a data: frame.
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(sock, "GET /events HTTP/1.1\r\nHost: x\r\n\r\n")
    {:ok, _headers} = :gen_tcp.recv(sock, 0, 2000)

    ref = make_ref()
    Process.sleep(50)
    Events.publish(ref, :tool_call, %{name: "grep", input: %{"pattern" => "x"}})

    {:ok, frame} = :gen_tcp.recv(sock, 0, 2000)
    assert frame =~ "data:"
    assert frame =~ "tool_call"
    :gen_tcp.close(sock)
  end
end
