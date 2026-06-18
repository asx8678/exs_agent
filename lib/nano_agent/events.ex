defmodule NanoAgent.Events do
  @moduledoc """
  Lightweight pub/sub over a `Registry` — zero external dependencies, a drop-in
  stand-in for `Phoenix.PubSub`. Agents publish lifecycle/tool events; the
  dashboard and persistence layer subscribe.

  Subscribers receive `{:nano_event, event}` messages where `event` is
  `%{ref:, type:, payload:, at:}`.
  """

  @doc false
  def child_spec(_opts) do
    Registry.child_spec(keys: :duplicate, name: __MODULE__)
  end

  @doc "Subscribe the calling process to all events, or to a single run's events."
  def subscribe(topic \\ :all), do: Registry.register(__MODULE__, topic, [])

  @doc "Publish an event for a run. Delivered to `:all` and `{:run, ref}` subscribers."
  def publish(ref, type, payload \\ %{}) do
    event = %{ref: ref, type: type, payload: payload, at: System.system_time(:millisecond)}
    dispatch(:all, event)
    dispatch({:run, ref}, event)
    :ok
  end

  defp dispatch(topic, event) do
    Registry.dispatch(__MODULE__, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:nano_event, event})
    end)
  rescue
    ArgumentError -> :ok
  end
end
