defmodule SymphonyElixir.Heartbeat do
  @moduledoc """
  Distributed-lock heartbeat renewal loop for Symphony (Spec M-7).

  The Orchestrator acquires the heartbeat lock at boot via
  `SymphonyElixir.Tracker.acquire_heartbeat/0`, then starts this GenServer to
  renew the lock every `ttl_ms / 3` ms. Renewal failures don't immediately
  knock the orchestrator over: instead we count elapsed time since the last
  successful renewal and flip into `degraded?` mode once that exceeds
  `ttl_ms`. While degraded, the orchestrator refuses to dispatch new agents
  but keeps monitoring existing ones. The orchestrator polls `degraded?/1`
  via the public API rather than coupling to internal state.

  This module never tries to acquire the lock itself — that's the
  Orchestrator's responsibility. If `acquire_heartbeat/0` keeps returning
  `{:error, ...}` for longer than `ttl_ms`, the lock will eventually
  expire and a different Symphony can take over; the local instance enters
  degraded mode in the meantime.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Tracker

  @type option ::
          {:ttl_ms, pos_integer()}
          | {:name, GenServer.name() | nil}
          | {:tracker_module, module()}
          | {:initial_success_at_ms, integer()}

  defmodule State do
    @moduledoc false

    @enforce_keys [:ttl_ms, :tracker_module]
    defstruct [
      :ttl_ms,
      :tracker_module,
      :timer_ref,
      :last_success_at_ms,
      degraded?: false,
      consecutive_failures: 0
    ]

    @type t :: %__MODULE__{
            ttl_ms: pos_integer(),
            tracker_module: module(),
            timer_ref: reference() | nil,
            last_success_at_ms: integer(),
            degraded?: boolean(),
            consecutive_failures: non_neg_integer()
          }
  end

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, nil} ->
        # `name: nil` is the explicit "anonymous" form used by tests that
        # spin up multiple Heartbeat processes side-by-side.
        GenServer.start_link(__MODULE__, opts)

      {:ok, name} ->
        GenServer.start_link(__MODULE__, opts, name: name)

      :error ->
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
    end
  end

  @doc """
  Returns `true` when the local heartbeat loop has failed to renew for longer
  than the configured TTL. Returns `false` when no Heartbeat process is
  registered under `name` so callers can treat "no heartbeat process" as
  "not degraded" (the renewal loop hasn't been started yet, e.g. during tests
  that don't exercise the heartbeat path).
  """
  @spec degraded?(GenServer.server()) :: boolean()
  def degraded?(server \\ __MODULE__) do
    case resolve_server(server) do
      nil -> false
      pid -> GenServer.call(pid, :degraded?)
    end
  end

  @doc """
  Returns a snapshot of the heartbeat tracker state. Used by tests and the
  status dashboard. Returns `nil` when no Heartbeat process is registered
  under `server`.
  """
  @spec snapshot(GenServer.server()) :: %{
          ttl_ms: pos_integer(),
          last_success_at_ms: integer(),
          degraded?: boolean(),
          consecutive_failures: non_neg_integer()
        } | nil
  def snapshot(server \\ __MODULE__) do
    case resolve_server(server) do
      nil -> nil
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc false
  @spec trigger_refresh_for_test(GenServer.server()) :: :ok
  def trigger_refresh_for_test(server \\ __MODULE__) do
    GenServer.call(server, :refresh_now)
  end

  defp resolve_server(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid, else: nil
  end

  defp resolve_server(other), do: GenServer.whereis(other)

  @impl true
  def init(opts) do
    ttl_ms = Keyword.fetch!(opts, :ttl_ms)
    tracker_module = Keyword.get(opts, :tracker_module, Tracker)

    initial_success_at =
      Keyword.get(opts, :initial_success_at_ms, System.monotonic_time(:millisecond))

    state = %State{
      ttl_ms: ttl_ms,
      tracker_module: tracker_module,
      last_success_at_ms: initial_success_at
    }

    {:ok, schedule_refresh(state)}
  end

  @impl true
  def handle_call(:degraded?, _from, %State{degraded?: degraded?} = state) do
    {:reply, degraded?, state}
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    snapshot = %{
      ttl_ms: state.ttl_ms,
      last_success_at_ms: state.last_success_at_ms,
      degraded?: state.degraded?,
      consecutive_failures: state.consecutive_failures
    }

    {:reply, snapshot, state}
  end

  def handle_call(:refresh_now, _from, %State{} = state) do
    state = run_refresh(state)
    {:reply, :ok, schedule_refresh(state)}
  end

  @impl true
  def handle_info(:refresh, %State{} = state) do
    state = run_refresh(state)
    {:noreply, schedule_refresh(state)}
  end

  def handle_info(_msg, %State{} = state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %State{timer_ref: timer_ref}) when is_reference(timer_ref) do
    Process.cancel_timer(timer_ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp run_refresh(%State{tracker_module: tracker_module} = state) do
    case safe_acquire(tracker_module) do
      :ok ->
        record_success(state)

      {:error, reason} ->
        record_failure(state, reason)
    end
  end

  defp safe_acquire(tracker_module) do
    try do
      tracker_module.acquire_heartbeat()
    catch
      kind, reason ->
        {:error, {:exception, kind, reason}}
    end
  end

  defp record_success(%State{degraded?: was_degraded?} = state) do
    if was_degraded? do
      Logger.warning(
        "Symphony heartbeat: exiting degraded mode (renewal succeeded after " <>
          "#{state.consecutive_failures} consecutive failure(s))"
      )
    end

    %{state | last_success_at_ms: System.monotonic_time(:millisecond), degraded?: false, consecutive_failures: 0}
  end

  defp record_failure(%State{} = state, reason) do
    consecutive = state.consecutive_failures + 1
    elapsed_ms = System.monotonic_time(:millisecond) - state.last_success_at_ms
    state = %{state | consecutive_failures: consecutive}

    cond do
      not state.degraded? and elapsed_ms > state.ttl_ms ->
        Logger.error(
          "Symphony heartbeat: entering degraded mode (renewal failing for " <>
            "#{elapsed_ms}ms; consecutive_failures=#{consecutive}; reason=#{inspect(reason)}); " <>
            "orchestrator will refuse to dispatch new agents until renewal succeeds"
        )

        %{state | degraded?: true}

      state.degraded? ->
        Logger.warning(
          "Symphony heartbeat: still degraded (renewal failed; " <>
            "elapsed_since_success_ms=#{elapsed_ms}; consecutive_failures=#{consecutive}; " <>
            "reason=#{inspect(reason)})"
        )

        state

      true ->
        Logger.warning(
          "Symphony heartbeat: renewal failed (consecutive_failures=#{consecutive}; " <>
            "elapsed_since_success_ms=#{elapsed_ms}; reason=#{inspect(reason)}); " <>
            "will retry on next interval"
        )

        state
    end
  end

  defp schedule_refresh(%State{ttl_ms: ttl_ms, timer_ref: prev_ref} = state) do
    if is_reference(prev_ref) do
      Process.cancel_timer(prev_ref)
    end

    # Spec M-7 AC1: renew every (heartbeat_ttl_ms / 3) ms. Clamp to 1ms so a
    # pathologically small TTL still produces a positive timer interval.
    delay_ms = max(div(ttl_ms, 3), 1)
    timer_ref = Process.send_after(self(), :refresh, delay_ms)
    %{state | timer_ref: timer_ref}
  end
end
