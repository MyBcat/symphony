defmodule SymphonyElixir.CostMeter do
  @moduledoc """
  Tracks per-day USD spend across all profiles to enforce the
  `cost_cap.daily_usd` kill switch (Spec M-3 / SYM-11923119477).

  Behaviour:

    * `add/3` — translates per-event `(profile, in_tokens, out_tokens)` into
      USD and adds it to today's running total. Called from the AgentRunner
      token telemetry hook.
    * `can_dispatch?/2` — pre-dispatch check. Returns `:ok` if the profile's
      `estimated_cost(profile, max_turns)` plus today's spend stays within
      `cost_cap.daily_usd`, otherwise `{:error, {:cost_cap_exceeded, ...}}`.
      Fail-closed: a profile missing per-token cost config refuses on
      uncertainty.
    * `today_spend/0` and `snapshot/0` — read accessors used by the TUI
      status dashboard.

  State persists to `state/cost_meter.json` (relative to the current working
  directory, mirroring the `PRSafety.PRState` convention) so a restart
  doesn't reset the count mid-day. The path is overridable via the
  `:cost_meter_state_path` application env so tests don't trample real state.

  Day rollover: on every public call, the meter compares the persisted
  `:date_utc` to the current UTC date. When they diverge, the running spend
  resets to 0 and the new date is persisted. The configurable timezone is
  deferred per the spec; UTC is the only supported boundary today.
  """

  use GenServer

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Profile

  @default_state_path "state/cost_meter.json"
  @cap_block_marker "## Symphony Cost Cap"

  @typedoc """
  Public snapshot exposed by `snapshot/0`. The TUI dashboard reads this on
  every render — keep the shape stable across versions.
  """
  @type snapshot :: %{
          date_utc: Date.t(),
          spend_usd: float(),
          cap_usd: float(),
          remaining_usd: float()
        }

  @typedoc """
  Refusal payload returned from `can_dispatch?/2`. `scope` is `:daily` for
  the global daily kill switch (the only scope wired up today). `current`
  is today's running spend; `cap` is `cost_cap.daily_usd`; `estimated` is
  the cost that would have tipped the meter past the cap.
  """
  @type refusal ::
          {:cost_cap_exceeded, :daily, current :: float(), cap :: float(),
           estimated :: float()}

  @typedoc "Token counts forwarded to `add/3`."
  @type token_input :: %{
          optional(:in_tokens) => non_neg_integer(),
          optional(:out_tokens) => non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Resolve the configured state file path. Defaults to
  `state/cost_meter.json` relative to the current working directory.
  """
  @spec path() :: String.t()
  def path do
    Application.get_env(:symphony_elixir, :cost_meter_state_path, @default_state_path)
  end

  @doc """
  Add token usage for `profile` to today's running total. Computes the USD
  delta as `in_tokens * cost_per_input_token_usd + out_tokens *
  cost_per_output_token_usd`. A profile missing either cost field is
  silently ignored on `add/3` — `can_dispatch?/2` is responsible for
  refusing those profiles before they ever dispatch, so any token telemetry
  from a misconfigured profile in flight is treated as already-paid-for and
  not double-counted.

  Returns the running total after the addition.
  """
  @spec add(GenServer.name() | pid(), Profile.t() | nil, token_input() | keyword()) :: float()
  def add(server \\ __MODULE__, profile, tokens) do
    GenServer.call(server, {:add, profile, normalize_tokens(tokens)})
  end

  @doc """
  Return today's running spend in USD. Triggers a UTC rollover check.
  """
  @spec today_spend(GenServer.name() | pid()) :: float()
  def today_spend(server \\ __MODULE__) do
    GenServer.call(server, :today_spend)
  end

  @doc """
  Return a snapshot suitable for the TUI status dashboard. Triggers a UTC
  rollover check.
  """
  @spec snapshot(GenServer.name() | pid()) :: snapshot()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @doc """
  Pre-dispatch check. Returns `:ok` when today's spend plus
  `estimated_cost(profile, max_turns)` would stay at or below the
  configured cap, otherwise `{:error, refusal()}`. A profile that lacks
  per-token cost config is treated as MAX (refused on uncertainty), per
  the spec's fail-closed constraint.

  `max_turns` defaults to `agent.max_turns` from `WORKFLOW.md`. Callers
  that have a tighter per-issue value should pass it explicitly.
  """
  @spec can_dispatch?(GenServer.name() | pid(), Profile.t(), pos_integer() | nil) ::
          :ok | {:error, refusal()}
  def can_dispatch?(server \\ __MODULE__, %Profile{} = profile, max_turns \\ nil) do
    GenServer.call(server, {:can_dispatch?, profile, max_turns})
  end

  @doc """
  Return the USD amount estimated to be consumed by a single agent run for
  `profile` over `max_turns`. Returns `:invalid` for profiles missing a
  cost configuration so the caller can refuse on uncertainty.

  The estimate uses a pessimistic per-turn token budget (defaulting to
  10K input + 5K output tokens per turn) so the kill switch refuses early
  rather than spilling past the cap.
  """
  @spec estimated_cost(Profile.t(), pos_integer() | nil) :: float() | :invalid
  def estimated_cost(%Profile{} = profile, max_turns) do
    case profile_cost_rates(profile) do
      :invalid ->
        :invalid

      {in_rate, out_rate} ->
        turns = max(max_turns || 1, 1)
        in_tokens = turns * input_tokens_per_turn()
        out_tokens = turns * output_tokens_per_turn()
        in_tokens * in_rate + out_tokens * out_rate
    end
  end

  @doc """
  Render the body of a `## Symphony Cost Cap` Workpad block describing the
  refused dispatch. Called from `AgentRunner` on a `cost_cap_exceeded`
  refusal; passed unchanged through `Tracker.upsert_workpad/2`.
  """
  @spec render_cap_workpad(map(), refusal()) :: String.t()
  def render_cap_workpad(session, {:cost_cap_exceeded, scope, current, cap, estimated})
      when is_map(session) do
    stamp = stamp_for_session(session)
    profile = stringify_field(Map.get(session, :profile_name))
    repo = stringify_field(Map.get(session, :repo))
    today = Date.utc_today() |> Date.to_iso8601()

    """
    #{@cap_block_marker}

    ```text
    #{stamp}
    ```

    ### Refusal

    - Date (UTC): `#{today}`
    - Scope: `#{scope}`
    - Profile: `#{profile}`
    - Repo: `#{repo}`
    - Today's spend: `$#{format_usd(current)}`
    - Cap: `$#{format_usd(cap)}`
    - Estimated dispatch cost: `$#{format_usd(estimated)}`

    Symphony refused dispatch because today's spend plus the estimated cost
    of this run exceeds `cost_cap.daily_usd`. The item stays in
    `Symphony Ready`. Operators can either bump the cap in `WORKFLOW.md` or
    wait for the UTC midnight rollover.
    """
  end

  @spec render_cap_workpad(map(), term()) :: String.t()
  def render_cap_workpad(session, _refusal) when is_map(session) do
    render_cap_workpad(session, {:cost_cap_exceeded, :daily, 0.0, 0.0, 0.0})
  end

  @doc false
  @spec reset!(GenServer.name() | pid()) :: :ok
  def reset!(server \\ __MODULE__) do
    GenServer.call(server, :reset)
  end

  ## --- GenServer ----------------------------------------------------------

  @impl true
  def init(_opts) do
    state =
      case load_persisted() do
        {:ok, persisted} -> persisted
        {:error, reason} ->
          Logger.warning(
            "CostMeter: failed to load #{path()}: #{inspect(reason)}; starting at $0.00 today"
          )

          fresh_state()
      end
      |> apply_rollover()

    {:ok, state}
  end

  @impl true
  def handle_call({:add, profile, %{in_tokens: in_tokens, out_tokens: out_tokens}}, _from, state) do
    state = apply_rollover(state)

    delta =
      case profile_cost_rates(profile) do
        :invalid ->
          # Profile has no cost config — `can_dispatch?/2` already refused
          # on uncertainty, so an in-flight token event from a misconfigured
          # profile shouldn't fabricate retroactive spend.
          0.0

        {in_rate, out_rate} ->
          max(0, in_tokens) * in_rate + max(0, out_tokens) * out_rate
      end

    new_total = round_usd(state.spend_usd + delta)
    new_state = %{state | spend_usd: new_total}

    persist(new_state)
    {:reply, new_total, new_state}
  end

  def handle_call(:today_spend, _from, state) do
    state = apply_rollover(state)
    {:reply, state.spend_usd, state}
  end

  def handle_call(:snapshot, _from, state) do
    state = apply_rollover(state)
    cap = current_cap()

    snapshot = %{
      date_utc: state.date_utc,
      spend_usd: state.spend_usd,
      cap_usd: cap,
      remaining_usd:
        if(cap > 0, do: max(0.0, round_usd(cap - state.spend_usd)), else: 0.0)
    }

    {:reply, snapshot, state}
  end

  def handle_call({:can_dispatch?, profile, max_turns}, _from, state) do
    state = apply_rollover(state)
    cap = current_cap()
    {:reply, evaluate_dispatch(state, cap, profile, max_turns), state}
  end

  def handle_call(:reset, _from, _state) do
    new_state = fresh_state()
    persist(new_state)
    {:reply, :ok, new_state}
  end

  ## --- Helpers ------------------------------------------------------------

  defp evaluate_dispatch(_state, cap, _profile, _max_turns) when cap <= 0.0, do: :ok

  defp evaluate_dispatch(state, cap, profile, max_turns) do
    resolved_max_turns = max_turns || default_max_turns()

    case estimated_cost(profile, resolved_max_turns) do
      :invalid ->
        # Fail-closed: missing cost config — refuse with estimated = cap so
        # the operator sees an estimate that trips the kill switch on
        # first encounter. Spec requirement: "treat its spend as MAX".
        {:error, {:cost_cap_exceeded, :daily, state.spend_usd, cap, cap}}

      estimated when is_number(estimated) ->
        if state.spend_usd + estimated > cap do
          {:error, {:cost_cap_exceeded, :daily, state.spend_usd, cap, round_usd(estimated)}}
        else
          :ok
        end
    end
  end

  defp normalize_tokens(tokens) when is_map(tokens) do
    %{
      in_tokens: clamp_non_neg(Map.get(tokens, :in_tokens, 0)),
      out_tokens: clamp_non_neg(Map.get(tokens, :out_tokens, 0))
    }
  end

  defp normalize_tokens(tokens) when is_list(tokens) do
    normalize_tokens(Map.new(tokens))
  end

  defp clamp_non_neg(value) when is_integer(value) and value >= 0, do: value
  defp clamp_non_neg(value) when is_integer(value), do: 0
  defp clamp_non_neg(_), do: 0

  defp profile_cost_rates(%Profile{
         cost_per_input_token_usd: in_rate,
         cost_per_output_token_usd: out_rate
       })
       when is_number(in_rate) and is_number(out_rate) and in_rate >= 0 and out_rate >= 0 do
    {in_rate, out_rate}
  end

  defp profile_cost_rates(_profile), do: :invalid

  defp current_cap do
    case safe_settings() do
      {:ok, settings} ->
        case Map.get(settings, :cost_cap) do
          %{daily_usd: cap} when is_number(cap) and cap > 0 -> cap * 1.0
          _ -> 0.0
        end

      :error ->
        0.0
    end
  end

  defp default_max_turns do
    case safe_settings() do
      {:ok, %{agent: %{max_turns: max_turns}}} when is_integer(max_turns) and max_turns > 0 ->
        max_turns

      _ ->
        20
    end
  end

  defp safe_settings do
    try do
      {:ok, Config.settings!()}
    rescue
      _ -> :error
    end
  end

  defp input_tokens_per_turn do
    Application.get_env(:symphony_elixir, :cost_meter_input_tokens_per_turn, 10_000)
  end

  defp output_tokens_per_turn do
    Application.get_env(:symphony_elixir, :cost_meter_output_tokens_per_turn, 5_000)
  end

  defp apply_rollover(%{date_utc: %Date{} = date} = state) do
    today = Date.utc_today()

    if Date.compare(today, date) == :eq do
      state
    else
      Logger.info(
        "CostMeter: UTC day rollover from #{Date.to_iso8601(date)} to #{Date.to_iso8601(today)}; resetting spend to $0.00"
      )

      new_state = %{state | date_utc: today, spend_usd: 0.0}
      persist(new_state)
      new_state
    end
  end

  defp apply_rollover(state) do
    new_state = fresh_state()
    persist(new_state)
    new_state
  end

  defp fresh_state do
    %{date_utc: Date.utc_today(), spend_usd: 0.0}
  end

  defp persist(state) do
    state_path = path()
    dir = Path.dirname(state_path)
    tmp_path = state_path <> ".tmp"

    body =
      Jason.encode!(%{
        "date_utc" => Date.to_iso8601(state.date_utc),
        "spend_usd" => state.spend_usd
      })

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp_path, body),
         :ok <- File.rename(tmp_path, state_path) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("CostMeter: failed to persist #{state_path}: #{inspect(reason)}")
        _ = File.rm(tmp_path)
        :ok
    end
  end

  defp load_persisted do
    case File.read(path()) do
      {:ok, ""} ->
        {:ok, fresh_state()}

      {:ok, body} ->
        decode(body)

      {:error, :enoent} ->
        {:ok, fresh_state()}

      {:error, _reason} = err ->
        err
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"date_utc" => date_str, "spend_usd" => spend}} when is_number(spend) ->
        case Date.from_iso8601(date_str) do
          {:ok, date} -> {:ok, %{date_utc: date, spend_usd: spend * 1.0}}
          {:error, reason} -> {:error, {:invalid_date, reason}}
        end

      {:ok, _other} ->
        {:error, :invalid_state_file}

      {:error, reason} ->
        {:error, {:state_decode_failed, reason}}
    end
  end

  defp round_usd(value) when is_number(value) do
    Float.round(value * 1.0, 4)
  end

  defp stamp_for_session(session) do
    host = stringify_field(Map.get(session, :host))
    workspace = Map.get(session, :workspace_path) || ""
    sha = stringify_field(Map.get(session, :short_sha))
    "#{host}:#{workspace}@#{sha}"
  end

  defp stringify_field(nil), do: "unknown"
  defp stringify_field(""), do: "unknown"
  defp stringify_field(value) when is_binary(value), do: value
  defp stringify_field(value), do: to_string(value)

  defp format_usd(value) when is_number(value) do
    :erlang.float_to_binary(value * 1.0, decimals: 2)
  end

  defp format_usd(_), do: "0.00"

  @doc false
  @spec marker() :: String.t()
  def marker, do: @cap_block_marker
end
