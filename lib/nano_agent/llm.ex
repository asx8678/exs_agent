defmodule NanoAgent.LLM do
  @moduledoc """
  Agent-facing LLM entrypoint. Resolves the configured provider, injects the
  default system prompt, and retries transient failures with exponential backoff
  + jitter. Blocking sleeps happen inside the calling agent's own process, so
  they never stall the orchestrator or other agents.
  """
  require Logger

  @max_retries 4

  @system """
  You are a focused execution agent. You are given a plan and a small set of
  tools (read, write, edit, list, glob, grep, bash). Carry out the plan using the
  tools, one step at a time. Prefer reading before writing. When the plan is fully
  complete, stop calling tools and reply with a short summary of what you did.
  """

  @spec chat([map()], [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, tools, opts \\ []) do
    provider =
      opts[:provider] ||
        Application.get_env(:nano_agent, :provider, NanoAgent.Provider.Anthropic)

    opts = Keyword.put_new(opts, :system, @system)
    with_retry(fn -> provider.chat(messages, tools, opts) end, 0)
  end

  defp with_retry(fun, attempt) do
    case fun.() do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if attempt < @max_retries and retryable?(reason) do
          delay = backoff_ms(attempt)
          Logger.warning("LLM transient #{inspect(reason)}; retry #{attempt + 1} in #{delay}ms")
          Process.sleep(delay)
          with_retry(fun, attempt + 1)
        else
          err
        end
    end
  end

  # HTTP statuses worth retrying.
  defp retryable?({:http, status, _}) when status in [408, 409, 429, 500, 502, 503, 504], do: true
  # :httpc / inet transient errors.
  defp retryable?({:failed_connect, _}), do: true

  defp retryable?(reason) when is_atom(reason),
    do: reason in [:timeout, :closed, :econnrefused, :nxdomain, :ehostunreach, :etimedout]

  defp retryable?(_), do: false

  defp backoff_ms(attempt) do
    unit = Application.get_env(:nano_agent, :retry_base_ms, 500)
    base = min(round(:math.pow(2, attempt) * unit), 20_000)
    base + :rand.uniform(div(base, 2) + 1)
  end
end
