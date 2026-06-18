defmodule NanoAgent.M6Test do
  use ExUnit.Case, async: false

  alias NanoAgent.{Safety, Tools, Approvals, Provider.Mock}

  setup do
    on_exit(fn ->
      Application.delete_env(:nano_agent, :mock)
      Application.put_env(:nano_agent, :sandbox, [])
      Application.put_env(:nano_agent, :bash_policy, [])
      Application.put_env(:nano_agent, :approvals, :auto_approve)
      Application.put_env(:nano_agent, :approval_tools, [])
    end)

    :ok
  end

  describe "path sandboxing" do
    test "confines paths to the root and blocks traversal" do
      root = Path.join(System.tmp_dir!(), "sbx_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      Application.put_env(:nano_agent, :sandbox, root: root, enforce: true)

      assert {:ok, _} = Safety.resolve("inside.txt")
      assert {:error, :denied} = Safety.resolve("../escape.txt")
      assert {:error, :denied} = Safety.resolve("/etc/passwd")

      # the tool refuses too
      assert Tools.run("read", %{"path" => "/etc/passwd"}) =~ "outside the allowed root"
    end
  end

  describe "bash policy" do
    test "deny patterns block commands" do
      Application.put_env(:nano_agent, :bash_policy, deny: [~r/rm\s+-rf/])
      refute Safety.allow_command?("rm -rf /tmp/x")
      assert Safety.allow_command?("ls -la")
      assert Tools.run("bash", %{"command" => "rm -rf whatever"}) =~ "blocked by bash policy"
    end

    test "allow list restricts to matching commands" do
      Application.put_env(:nano_agent, :bash_policy, allow: ["echo", ~r/^ls/])
      assert Safety.allow_command?("echo hi")
      assert Safety.allow_command?("ls -la")
      refute Safety.allow_command?("curl evil.com")
    end
  end

  describe "approval gate" do
    test "destructive bash is flagged for approval" do
      assert Safety.requires_approval?("bash", %{"command" => "rm -rf /"})
      refute Safety.requires_approval?("bash", %{"command" => "ls"})
    end

    test "auto_deny blocks a flagged tool but the run still completes" do
      Application.put_env(:nano_agent, :approvals, :auto_deny)
      Application.put_env(:nano_agent, :approval_tools, ["write"])

      Application.put_env(:nano_agent, :mock, [
        Mock.tool_use("t1", "write", %{"path" => "/tmp/x", "content" => "hi"}),
        Mock.end_turn("done despite denial")
      ])

      assert {:ok, r} = NanoAgent.run("write a file", 5_000)
      assert r.status == :ok
      assert r.summary =~ "done despite denial"
    end

    test "manual approval unblocks a waiting agent" do
      Application.put_env(:nano_agent, :approvals, :manual)
      Application.put_env(:nano_agent, :approval_tools, ["write"])
      tmp = Path.join(System.tmp_dir!(), "appr_#{System.unique_integer([:positive])}.txt")

      Application.put_env(:nano_agent, :mock, [
        Mock.tool_use("t1", "write", %{"path" => tmp, "content" => "approved!"}),
        Mock.end_turn("wrote it")
      ])

      task = Task.async(fn -> NanoAgent.run("write the file", 5_000) end)

      id = wait_for_pending(1_000)
      assert is_binary(id)
      Approvals.approve(id)

      assert {:ok, r} = Task.await(task, 5_000)
      assert r.status == :ok
      assert File.read!(tmp) == "approved!"
      File.rm(tmp)
    end
  end

  defp wait_for_pending(0), do: nil

  defp wait_for_pending(budget) do
    case Approvals.pending() do
      [id | _] ->
        id

      [] ->
        Process.sleep(20)
        wait_for_pending(max(budget - 20, 0))
    end
  end
end
