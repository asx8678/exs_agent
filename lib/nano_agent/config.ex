defmodule NanoAgent.Config do
  @moduledoc """
  Validates the `:nano_agent` application config and surfaces problems early.
  `validate/0` returns a list of human-readable issues (empty = all good);
  `warn!/0` logs each at boot. Defaults mirror the usage sites so unset keys are
  not falsely flagged.
  """
  require Logger

  @approval_modes [:auto_approve, :auto_deny, :manual]

  @spec validate() :: [String.t()]
  def validate do
    []
    |> check_provider()
    |> check_pos_int(:max_concurrency, 5)
    |> check_cap(:max_agents, :infinity)
    |> check_cap(:max_run_tokens, :infinity)
    |> check_nonneg_int(:max_subagent_depth, 2)
    |> check_pos_int(:retry_base_ms, 500)
    |> check_context()
    |> check_approvals()
    |> check_sandbox()
    |> Enum.reverse()
  end

  @spec warn!() :: :ok
  def warn! do
    for issue <- validate(), do: Logger.warning("config: #{issue}")
    :ok
  end

  # ---- checks ----

  defp check_provider(issues) do
    p = get(:provider, nil)

    cond do
      is_nil(p) ->
        add(issues, "provider is not set")

      not (is_atom(p) and Code.ensure_loaded?(p) and function_exported?(p, :chat, 3)) ->
        add(issues, "provider #{inspect(p)} does not implement chat/3")

      true ->
        issues
    end
  end

  defp check_pos_int(issues, key, default) do
    case get(key, default) do
      n when is_integer(n) and n > 0 -> issues
      v -> add(issues, "#{key} must be a positive integer, got #{inspect(v)}")
    end
  end

  defp check_nonneg_int(issues, key, default) do
    case get(key, default) do
      n when is_integer(n) and n >= 0 -> issues
      v -> add(issues, "#{key} must be a non-negative integer, got #{inspect(v)}")
    end
  end

  defp check_cap(issues, key, default) do
    case get(key, default) do
      :infinity -> issues
      n when is_integer(n) and n > 0 -> issues
      v -> add(issues, "#{key} must be :infinity or a positive integer, got #{inspect(v)}")
    end
  end

  defp check_context(issues) do
    mx = get(:context_max_messages, 40)
    kp = get(:context_keep_recent, 16)

    cond do
      not (is_integer(mx) and is_integer(kp)) ->
        add(issues, "context_max_messages/context_keep_recent must be integers")

      mx <= kp ->
        add(issues, "context_max_messages (#{mx}) must be > context_keep_recent (#{kp})")

      true ->
        issues
    end
  end

  defp check_approvals(issues) do
    m = get(:approvals, :auto_approve)

    if m in @approval_modes,
      do: issues,
      else: add(issues, "approvals must be one of #{inspect(@approval_modes)}, got #{inspect(m)}")
  end

  defp check_sandbox(issues) do
    cfg = get(:sandbox, [])

    if Keyword.keyword?(cfg) && cfg[:enforce] && not is_binary(cfg[:root]),
      do: add(issues, "sandbox enforce: true requires a string :root"),
      else: issues
  end

  # ---- helpers ----

  defp get(key, default), do: Application.get_env(:nano_agent, key, default)
  defp add(issues, msg), do: [msg | issues]
end
