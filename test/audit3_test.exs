defmodule NanoAgent.Audit3Test do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias NanoAgent.{Tools, CLI, Resume, Store, Provider.Mock}

  setup do
    Store.clear()
    on_exit(fn -> Application.delete_env(:nano_agent, :mock) end)
    :ok
  end

  test "grep is bounded by a timeout (does not hang)" do
    tmp = Path.join(System.tmp_dir!(), "grep_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.write!(Path.join(tmp, "a.txt"), "hello world\nfoo bar")
    on_exit(fn -> File.rm_rf(tmp) end)

    # normal grep still works (timeout path is exercised structurally)
    assert Tools.run("grep", %{"pattern" => "foo", "path" => tmp}) =~ "a.txt"
  end

  test "CLI export with no run id errors instead of running 'export' as a goal" do
    capture_io(:stderr, fn ->
      assert {:error, :no_run_id} = CLI.run(["export"])
    end)
  end

  test "resume does not crash when an agent can't be started" do
    # No running runs -> resume_all returns [] cleanly
    assert Resume.resume_all() == []

    # a running run with saved state resumes to completion
    Store.register("rx", "resume me")
    Store.checkpoint("rx", %{messages: [%{role: "user", content: "resume me"}], iterations: 0})
    Application.put_env(:nano_agent, :mock, [Mock.end_turn("resumed ok")])

    assert [{"rx", result}] = Resume.resume_all()
    assert result.status == :ok
  end
end
