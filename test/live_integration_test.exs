defmodule NanoAgent.LiveIntegrationTest do
  @moduledoc """
  Real-provider smoke test. Excluded by default (the suite stays offline); run with:

      DEEPSEEK_API_KEY=sk-...  mix test --include live
      ANTHROPIC_API_KEY=sk-... mix test --include live

  Picks DeepSeek if its key is set, else Anthropic. Makes a couple of real calls.
  """
  use ExUnit.Case, async: false

  @moduletag :live

  setup do
    prev = Application.get_env(:nano_agent, :provider)

    provider =
      cond do
        System.get_env("DEEPSEEK_API_KEY") -> NanoAgent.Provider.DeepSeek
        System.get_env("ANTHROPIC_API_KEY") -> NanoAgent.Provider.Anthropic
        true -> flunk("set DEEPSEEK_API_KEY or ANTHROPIC_API_KEY to run :live tests")
      end

    Application.put_env(:nano_agent, :provider, provider)
    on_exit(fn -> Application.put_env(:nano_agent, :provider, prev) end)
    {:ok, provider: provider}
  end

  test "a single plan completes end-to-end against the real API", %{provider: provider} do
    {:ok, r} = NanoAgent.run("Reply with exactly the single word: ok", 60_000)

    assert r.status == :ok, "provider #{inspect(provider)} returned #{inspect(r)}"
    assert r.tokens.output > 0
  end

  test "a tool-using plan completes (validates tool calling end-to-end)" do
    tmp = Path.join(System.tmp_dir!(), "live_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cd!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    {:ok, r} =
      NanoAgent.run(
        "Use the bash tool to create a file ok.txt containing 'hi', then read it back and report its contents.",
        120_000
      )

    assert r.status == :ok
    assert r.tool_calls >= 1
  end
end
