defmodule NanoAgent.HardeningTest do
  use ExUnit.Case, async: false

  alias NanoAgent.{Tools, Store}

  setup do
    on_exit(fn ->
      Application.put_env(:nano_agent, :http_fetch_allow_private, false)
      Application.put_env(:nano_agent, :http_fetch_enabled, true)
    end)

    :ok
  end

  test "tool output with invalid UTF-8 is scrubbed to valid UTF-8" do
    # printf raw bytes 0xff 0xfe — invalid UTF-8
    out = Tools.run("bash", %{"command" => ~S(printf '\xff\xfe ok')})
    assert String.valid?(out)
    assert out =~ "ok"
  end

  describe "http_fetch SSRF guard" do
    test "refuses loopback by default" do
      assert Tools.run("http_fetch", %{"url" => "http://127.0.0.1:1/x"}) =~
               "refusing to fetch private"
    end

    test "refuses link-local metadata endpoint" do
      assert Tools.run("http_fetch", %{"url" => "http://169.254.169.254/latest/meta-data"}) =~
               "refusing to fetch private"
    end

    test "refuses unresolvable hosts" do
      assert Tools.run("http_fetch", %{"url" => "http://no.such.host.invalid/"}) =~
               "refusing to fetch private"
    end

    test "can be disabled entirely" do
      Application.put_env(:nano_agent, :http_fetch_enabled, false)
      assert Tools.run("http_fetch", %{"url" => "https://example.com"}) =~ "disabled"
    end
  end

  test "store retention prunes oldest finished runs" do
    Store.clear()
    Application.put_env(:nano_agent, :max_stored_runs, 3)
    on_exit(fn -> Application.put_env(:nano_agent, :max_stored_runs, 1000) end)

    # register 5 runs and finish them; only the newest 3 should remain
    for i <- 1..5 do
      Store.register("r#{i}", "plan #{i}")
      Store.finish("r#{i}", %NanoAgent.Result{status: :ok, summary: "s#{i}"})
      Process.sleep(2)
    end

    ids = Store.list() |> Enum.map(& &1.id) |> MapSet.new()
    assert MapSet.size(ids) <= 3
    # the two oldest are gone
    refute "r1" in ids
    refute "r2" in ids
  end
end
