defmodule NanoAgent.Approvals do
  @moduledoc """
  Human-in-the-loop approval gate for flagged tool calls. When an agent is about
  to run a tool that `NanoAgent.Safety.requires_approval?/2` flags, it calls
  `request/1`, which blocks that agent (only) until a decision is made.

  Mode is set by `config :nano_agent, :approvals`:

    * `:auto_approve` (default) — approve immediately (good for trusted/headless)
    * `:auto_deny`              — deny immediately
    * `:manual`                 — hold until `approve/1` or `deny/1` is called
                                  (surface pending requests in the dashboard/CLI)
  """
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{pending: %{}}, name: __MODULE__)

  @doc "Block until the tool call is approved or denied. Returns :approved | :denied."
  def request(meta), do: GenServer.call(__MODULE__, {:request, meta}, :infinity)

  @doc "Ids of requests awaiting a manual decision."
  def pending, do: GenServer.call(__MODULE__, :pending)

  def approve(id), do: GenServer.cast(__MODULE__, {:resolve, id, :approved})
  def deny(id), do: GenServer.cast(__MODULE__, {:resolve, id, :denied})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:request, meta}, from, state) do
    id = :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)

    NanoAgent.Events.publish(meta[:ref] || :approvals, :approval_requested, %{
      id: id,
      name: meta[:name],
      input: meta[:input]
    })

    case Application.get_env(:nano_agent, :approvals, :auto_approve) do
      :auto_approve -> {:reply, :approved, state}
      :auto_deny -> {:reply, :denied, state}
      :manual -> {:noreply, put_in(state.pending[id], from)}
    end
  end

  def handle_call(:pending, _from, state), do: {:reply, Map.keys(state.pending), state}

  @impl true
  def handle_cast({:resolve, id, decision}, state) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        {:noreply, state}

      {from, pending} ->
        GenServer.reply(from, decision)
        NanoAgent.Events.publish(:approvals, :approval_resolved, %{id: id, decision: decision})
        {:noreply, %{state | pending: pending}}
    end
  end
end
