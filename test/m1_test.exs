defmodule NanoAgent.M1Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Tools, Result, Provider.Mock}

  setup do
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    tmp = Path.join(System.tmp_dir!(), "nano_m1_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "tools" do
    test "write then read round-trips", %{tmp: tmp} do
      path = Path.join(tmp, "a.txt")
      assert Tools.run("write", %{"path" => path, "content" => "hello"}) =~ "wrote 5 bytes"
      assert Tools.run("read", %{"path" => path}) == "hello"
    end

    test "edit requires a unique match", %{tmp: tmp} do
      path = Path.join(tmp, "b.txt")
      File.write!(path, "foo bar foo")

      assert Tools.run("edit", %{"path" => path, "old_string" => "foo", "new_string" => "x"}) =~
               "appears 2 times"

      assert Tools.run("edit", %{"path" => path, "old_string" => "bar", "new_string" => "baz"}) =~
               "edited"

      assert File.read!(path) == "foo baz foo"
    end

    test "list, glob and grep", %{tmp: tmp} do
      File.write!(Path.join(tmp, "x.ex"), "defmodule X do\n  def hi, do: :ok\nend\n")
      File.write!(Path.join(tmp, "y.txt"), "nothing here")

      assert Tools.run("list", %{"path" => tmp}) =~ "x.ex"
      assert Tools.run("glob", %{"pattern" => Path.join(tmp, "*.ex")}) =~ "x.ex"

      grep = Tools.run("grep", %{"pattern" => "def hi", "path" => tmp})
      assert grep =~ "x.ex:2:"
    end

    test "bash runs and unknown tool is graceful" do
      assert Tools.run("bash", %{"command" => "echo hi"}) == "hi\n"
      assert Tools.run("nope", %{}) =~ "unknown tool"
    end

    test "run/2 never raises on bad input" do
      assert Tools.run("read", %{}) =~ "error"
    end
  end

  describe "agent loop" do
    test "executes a tool then finishes with a structured Result" do
      Application.put_env(:nano_agent, :mock, [
        Mock.tool_use("t1", "bash", %{"command" => "echo step1"}),
        Mock.end_turn("done: ran one command")
      ])

      assert {:ok, %Result{} = r} = NanoAgent.run("run echo", 5_000)
      assert r.status == :ok
      assert r.summary =~ "done: ran one command"
      assert r.tool_calls == 1
      assert r.iterations == 1
      assert r.tokens.output > 0
    end

    test "reports :error on a non-retryable provider failure" do
      Application.put_env(:nano_agent, :mock, fn _m, _t, _o -> {:error, :boom} end)
      assert {:ok, %Result{status: :error, error: :boom}} = NanoAgent.run("x", 5_000)
    end
  end
end
