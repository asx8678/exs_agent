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
  You are a focused execution agent. You are given a plan and a set of tools
  (read, write, edit, multi_edit, list, glob, grep, http_fetch, bash). Carry out
  the plan using the tools, one step at a time. Prefer reading before writing and
  prefer edit/multi_edit over rewriting whole files. When the plan is fully
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
          delay = backoff_ms(attempt, reason)
          Logger.warning("LLM transient #{inspect(reason)}; retry #{attempt + 1} in #{delay}ms")
          Process.sleep(delay)
          with_retry(fun, attempt + 1)
        else
          err
        end
    end
  end

  @retry_status [408, 409, 429, 500, 502, 503, 504]

  # HTTP statuses worth retrying (with or without captured headers).
  defp retryable?({:http, status, _body}) when status in @retry_status, do: true
  defp retryable?({:http, status, _headers, _body}) when status in @retry_status, do: true
  defp retryable?({:failed_connect, _}), do: true

  defp retryable?(reason) when is_atom(reason),
    do: reason in [:timeout, :closed, :econnrefused, :nxdomain, :ehostunreach, :etimedout]

  defp retryable?(_), do: false

  # Honor a server-provided Retry-After header when present; else exponential backoff.
  defp backoff_ms(attempt, {:http, _status, headers, _body}),
    do: retry_after_ms(headers) || exp_backoff(attempt)

  defp backoff_ms(attempt, _reason), do: exp_backoff(attempt)

  defp exp_backoff(attempt) do
    unit = Application.get_env(:nano_agent, :retry_base_ms, 500)
    base = min(round(:math.pow(2, attempt) * unit), 20_000)
    base + :rand.uniform(div(base, 2) + 1)
  end

  defp retry_after_ms(headers) do
    with value when is_binary(value) <- find_header(headers, "retry-after"),
         {secs, _} <- Integer.parse(value) do
      secs * 1000
    else
      _ -> nil
    end
  end

  defp find_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name, do: to_string(v)
    end)
  end

  defp find_header(_, _), do: nil
end
