defmodule NanoAgent.DoctorTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias NanoAgent.{CLI, Provider.Mock}

  setup do
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "doctor reports provider and probes with a minimal request" do
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("ok")])

    out = capture_io(fn -> assert {:ok, _} = CLI.run(["doctor"]) end)

    assert out =~ "provider:"
    assert out =~ "status:  ok"
    assert out =~ "reply:   ok"
  end
end
