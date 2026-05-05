defmodule SymphonyElixir.Secrets.BootCheck do
  @moduledoc """
  Boot-time validation that every secret declared in `WORKFLOW.md`
  `repos.<key>.secrets` resolves successfully against AWS Secrets Manager via
  `secret_exec.py` (Spec 4 §2.4 / SYM-11923119480 AC#4).

  When the check passes, Symphony boots normally. When it fails, we log the
  missing PATHS only (never values) and return `{:error, ...}`; the caller is
  responsible for refusing to start.

  Disabled by default in test/dev environments via the
  `:symphony_elixir, :secrets_boot_check` application env. Production CLI sets
  the flag to `:enforce` so a missing secret refuses boot.
  """

  require Logger

  alias SymphonyElixir.{Config, Secrets.Resolver}

  @type mode :: :enforce | :warn | :skip

  @doc """
  Run the boot check. The mode controls behaviour on failure:

    * `:enforce` (default in production CLI): returns `{:error, missing}` so
      the caller refuses to start.
    * `:warn`: logs missing paths but returns `:ok`.
    * `:skip`: bypasses the check entirely.

  Mode resolution order:

    1. Explicit `mode` argument
    2. `Application.get_env(:symphony_elixir, :secrets_boot_check)`
    3. `:skip` (Mix test/dev default)
  """
  @spec run(mode() | nil) :: :ok | {:error, [tuple()]}
  def run(mode \\ nil) do
    resolved_mode = mode || Application.get_env(:symphony_elixir, :secrets_boot_check, :skip)

    do_run(resolved_mode)
  end

  defp do_run(:skip) do
    Logger.debug("Symphony secrets boot check skipped")
    :ok
  end

  defp do_run(mode) when mode in [:enforce, :warn] do
    secrets_by_repo = safely_secrets_by_repo()

    if map_size(secrets_by_repo) == 0 do
      Logger.info("Symphony secrets boot check: no per-repo secrets declared, skipping AWS probe")
      :ok
    else
      secret_exec = safely_secret_exec_path()

      case Resolver.check_all(secrets_by_repo, secret_exec_path: secret_exec) do
        :ok ->
          report_summary(secrets_by_repo)
          :ok

        {:error, missing} ->
          report_failures(missing)

          case mode do
            :enforce -> {:error, missing}
            :warn -> :ok
          end
      end
    end
  end

  defp do_run(other) do
    Logger.warning(
      "Symphony secrets boot check ignoring unknown mode #{inspect(other)}; treating as :skip"
    )

    :ok
  end

  defp safely_secrets_by_repo do
    Config.secrets_by_repo()
  rescue
    error in [ArgumentError] ->
      Logger.warning("Symphony secrets boot check could not load WORKFLOW.md: #{Exception.message(error)}")
      %{}
  end

  defp safely_secret_exec_path do
    Config.secret_exec_path()
  rescue
    error in [ArgumentError] ->
      Logger.warning("Symphony secrets boot check defaulting secret_exec.py path: #{Exception.message(error)}")
      Resolver.default_secret_exec_path()
  end

  defp report_summary(secrets_by_repo) do
    total =
      secrets_by_repo
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    Logger.info(
      "Symphony secrets boot check passed: #{total} secret(s) across #{map_size(secrets_by_repo)} repo(s)"
    )

    Enum.each(secrets_by_repo, fn {repo_key, refs} ->
      env_names = Resolver.declared_env_names(refs)

      Logger.info(
        "Symphony secrets boot check: repo=#{repo_key} env_names=#{Enum.join(env_names, ",")}"
      )
    end)
  end

  defp report_failures(missing) do
    Logger.error(
      "Symphony secrets boot check FAILED — refusing to start until all paths resolve. " <>
        "missing=#{format_missing(missing)}"
    )

    Enum.each(missing, fn
      {repo_key, ref, reason} when is_binary(ref) ->
        path = format_path(ref)
        Logger.error("  - repo=#{repo_key} secret_path=#{path} reason=#{inspect(reason_summary(reason))}")

      {label, _ref, reason} ->
        Logger.error("  - #{label} reason=#{inspect(reason_summary(reason))}")
    end)
  end

  defp format_missing(missing) do
    missing
    |> Enum.map(fn
      {repo_key, ref, _reason} when is_binary(ref) ->
        "#{repo_key}/#{format_path(ref)}"

      {label, _ref, _reason} ->
        to_string(label)
    end)
    |> Enum.join(", ")
  end

  defp format_path(ref) when is_binary(ref) do
    case Resolver.parse_ref(ref) do
      {:ok, %{secret_id: secret_id, env: env}} -> "#{secret_id}->#{env}"
      _ -> ref
    end
  end

  defp reason_summary({:secret_exec_nonzero, status, _output}), do: {:secret_exec_nonzero, status}
  defp reason_summary({:secret_resolution_failed, status, _output}), do: {:secret_resolution_failed, status}
  defp reason_summary(other), do: other
end
