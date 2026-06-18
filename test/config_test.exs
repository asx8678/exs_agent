defmodule NanoAgent.ConfigTest do
  use ExUnit.Case, async: false

  alias NanoAgent.Config

  test "the default/test config validates clean" do
    assert Config.validate() == []
  end

  test "flags a non-positive concurrency" do
    prev = Application.get_env(:nano_agent, :max_concurrency)
    Application.put_env(:nano_agent, :max_concurrency, 0)
    on_exit(fn -> Application.put_env(:nano_agent, :max_concurrency, prev) end)

    assert Enum.any?(Config.validate(), &(&1 =~ "max_concurrency"))
  end

  test "flags an invalid provider" do
    prev = Application.get_env(:nano_agent, :provider)
    Application.put_env(:nano_agent, :provider, NotAModule)
    on_exit(fn -> Application.put_env(:nano_agent, :provider, prev) end)

    assert Enum.any?(Config.validate(), &(&1 =~ "chat/3"))
  end

  test "flags context window inversion and enforced sandbox without a root" do
    prev_keep = Application.get_env(:nano_agent, :context_keep_recent)
    Application.put_env(:nano_agent, :context_keep_recent, 999)
    Application.put_env(:nano_agent, :sandbox, enforce: true)

    on_exit(fn ->
      Application.put_env(:nano_agent, :context_keep_recent, prev_keep)
      Application.put_env(:nano_agent, :sandbox, [])
    end)

    issues = Config.validate()
    assert Enum.any?(issues, &(&1 =~ "context_max_messages"))
    assert Enum.any?(issues, &(&1 =~ "sandbox"))
  end
end
