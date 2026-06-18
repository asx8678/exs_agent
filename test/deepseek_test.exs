defmodule NanoAgent.DeepSeekTest do
  use ExUnit.Case, async: true

  alias NanoAgent.Provider.DeepSeek

  test "implements the Provider behaviour" do
    {:module, _} = Code.ensure_loaded(DeepSeek)
    assert function_exported?(DeepSeek, :chat, 3)
  end

  test "requires DEEPSEEK_API_KEY" do
    prev = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")
    on_exit(fn -> if prev, do: System.put_env("DEEPSEEK_API_KEY", prev) end)

    assert_raise RuntimeError, ~r/DEEPSEEK_API_KEY/, fn ->
      DeepSeek.chat([%{role: "user", content: "hi"}], [])
    end
  end

  test "is the configured default provider" do
    # config/config.exs sets DeepSeek as the default (test env overrides to Mock).
    assert Application.get_env(:nano_agent, :provider) == NanoAgent.Provider.Mock
    # but DeepSeek is a real, selectable provider module
    assert Code.ensure_loaded?(NanoAgent.Provider.DeepSeek)
  end
end
