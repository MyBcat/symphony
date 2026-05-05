defmodule SymphonyElixir.Monday.PHIGate do
  @moduledoc """
  PHI gate refusal flow shared by `SymphonyElixir.Orchestrator` (poll-time
  dispatch) and the boot-time scan.

  Spec M-6 §AC1: any PHI finding flips the item's Symphony Status to
  "Cancelled" (via `Tracker.update_issue_state/2`) and posts a
  `## Symphony PHI Refusal` Monday Update (via `Tracker.post_phi_refusal/2`)
  whose body lists only the finding *kinds* — never the matched text.

  Spec M-6 §Constraints: ZERO PHI may appear in logs, stdout, or Workpad
  bodies. Callers MUST pass an offender record built by `Monday.Adapter` —
  which already strips matched text — and this module never accepts the
  raw findings shape from `PHIDetector.scan/1`.
  """

  require Logger

  alias SymphonyElixir.{Config, Tracker}
  alias SymphonyElixir.Monday.Workpad

  @type offender :: Tracker.phi_offender()

  @doc """
  Read the current `phi_gate.mode` setting. Defaults to `:strict` when the
  config is missing or malformed; this is the refuse-default per Spec M-6 §AC2.
  """
  @spec mode() :: :strict | :warn
  def mode do
    case Config.settings() do
      {:ok, settings} -> mode_from_settings(settings)
      _ -> :strict
    end
  end

  @spec mode_from_settings(SymphonyElixir.Config.Schema.t()) :: :strict | :warn
  def mode_from_settings(%SymphonyElixir.Config.Schema{phi_gate: %{mode: "warn"}}), do: :warn
  def mode_from_settings(_), do: :strict

  @doc """
  Apply the strict-mode refusal flow to a single PHI offender:
    1. Post `## Symphony PHI Refusal` Monday Update with finding kinds only.
    2. Transition the item's Symphony Status to "Cancelled".

  Returns `:ok` even when individual writes fail (errors are logged) so a
  partial Monday outage does not poison subsequent dispatches in the same
  tick.
  """
  @spec refuse(offender(), keyword()) :: :ok
  def refuse(offender, opts \\ []) when is_map(offender) do
    profile_name = Keyword.get(opts, :profile_name)

    session = %{
      identifier: offender.identifier,
      profile_name: profile_name || "unknown"
    }

    body = Workpad.render_phi_refusal(session, offender.kinds)

    Logger.warning("Symphony PHI gate refusing item identifier=#{offender.identifier} kinds=#{inspect(offender.kinds)}; flipping to Cancelled")

    case Tracker.post_phi_refusal(offender.id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Symphony PHI gate failed to post refusal for identifier=#{offender.identifier}: #{inspect(reason)}")

        :ok
    end

    case Tracker.update_issue_state(offender.id, "Cancelled") do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Symphony PHI gate failed to flip status to Cancelled for identifier=#{offender.identifier}: #{inspect(reason)}")

        :ok
    end

    :ok
  end

  @doc """
  Apply the warn-mode refusal flow: log only, no Monday writes, no status
  change. Spec M-6 §AC2: warn mode preserves existing behaviour for operators
  who explicitly opt out of strict refusal.
  """
  @spec warn(offender()) :: :ok
  def warn(offender) when is_map(offender) do
    Logger.warning(
      "Symphony PHI gate (warn mode) detected PHI in item identifier=#{offender.identifier} kinds=#{inspect(offender.kinds)}; continuing without status change"
    )

    :ok
  end

  @doc """
  Process a list of PHI offenders according to the configured `phi_gate.mode`.
  In `:strict` mode each offender is refused (Cancelled + Workpad refusal). In
  `:warn` mode each offender is logged. Returns `:ok` regardless.
  """
  @spec process_offenders([offender()], keyword()) :: :ok
  def process_offenders([], _opts), do: :ok

  def process_offenders(offenders, opts) when is_list(offenders) do
    case mode() do
      :strict -> Enum.each(offenders, &refuse(&1, opts))
      :warn -> Enum.each(offenders, &warn/1)
    end

    :ok
  end
end
