defmodule SymphonyElixir.CodexReview.Default do
  @moduledoc """
  Default `SymphonyElixir.CodexReview` implementation. Shells out to the
  `codex` CLI in `exec` (one-shot) mode.

  The invocation is decoupled from the long-running app-server adapter
  (`SymphonyElixir.Codex.Adapter`) — Codex review is fundamentally a
  non-streaming, non-tool-using CLI call.

  Captured output is scrubbed via `SymphonyElixir.Secrets.Scrubber` before
  return so resolved per-repo secrets never leak into the rendered Workpad.
  """

  @behaviour SymphonyElixir.CodexReview

  alias SymphonyElixir.Secrets.Scrubber

  require Logger

  @codex_command "codex"
  @default_review_timeout_ms 300_000
  @default_model "gpt-5.5"
  @default_reasoning_effort "xhigh"

  @impl true
  def review(%{prompt: prompt, cwd: cwd, profile_config: profile_config})
      when is_binary(prompt) and is_map(profile_config) do
    args = build_args(prompt, profile_config)
    cwd_to_use = cwd_for_exec(cwd)
    timeout_ms = review_timeout_ms(profile_config)

    case run_codex(args, cwd_to_use, timeout_ms) do
      {:ok, output} ->
        {:ok, Scrubber.scrub(output)}

      {:error, _} = err ->
        err
    end
  end

  def review(_), do: {:error, :invalid_codex_review_input}

  @doc false
  @spec build_args(String.t(), map()) :: [String.t()]
  def build_args(prompt, profile_config) when is_binary(prompt) and is_map(profile_config) do
    model = profile_value(profile_config, "model", @default_model)
    reasoning_effort = profile_value(profile_config, "reasoning_effort", @default_reasoning_effort)

    [
      "exec",
      "--skip-git-repo-check",
      "--config",
      ~s(model="#{model}"),
      "--config",
      "model_reasoning_effort=#{reasoning_effort}",
      prompt
    ]
  end

  defp profile_value(profile_config, key, default) do
    case Map.get(profile_config, key) || Map.get(profile_config, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  # Spec 4 §2.8a defense in depth: only run `codex exec` from a directory
  # that's (a) an existing directory AND (b) a descendant of Symphony's
  # configured `workspace.root`. Codex CLI inherits its cwd into any
  # tools it spawns; running from an arbitrary path could give an
  # accidental Codex tool call read-access to operator home / the
  # symphony repo itself / other repos. If the supplied cwd doesn't
  # canonicalize cleanly under workspace.root, fall back to the system
  # tmp dir (which is always safe).
  defp cwd_for_exec(cwd) when is_binary(cwd) and cwd != "" do
    if File.dir?(cwd) and cwd_under_workspace_root?(cwd) do
      cwd
    else
      System.tmp_dir!()
    end
  end

  defp cwd_for_exec(_), do: System.tmp_dir!()

  defp cwd_under_workspace_root?(cwd) do
    case workspace_root() do
      nil ->
        # No configured workspace root → default to safe fallback.
        false

      root ->
        canonical_cwd = Path.expand(cwd)
        canonical_root = Path.expand(root)

        # Allow exact match OR descendant; reject siblings or unrelated.
        canonical_cwd == canonical_root or
          String.starts_with?(canonical_cwd <> "/", canonical_root <> "/")
    end
  rescue
    _ -> false
  end

  defp workspace_root do
    SymphonyElixir.Config.settings!().workspace.root
  rescue
    _ -> nil
  end

  defp review_timeout_ms(profile_config) do
    case Map.get(profile_config, "review_timeout_ms") ||
           Map.get(profile_config, :review_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> @default_review_timeout_ms
    end
  end

  defp run_codex(args, cwd, timeout_ms) do
    case System.find_executable(@codex_command) do
      nil ->
        {:error, :codex_not_found}

      _executable ->
        do_run_codex(args, cwd, timeout_ms)
    end
  end

  # Run codex exec under a hard timeout via Task. System.cmd has no
  # timeout option; if codex hangs, the calling Task would otherwise leak
  # forever under the orchestrator's TaskSupervisor. Spawn the System.cmd
  # call in an inner Task and force-kill it with `Task.shutdown(:brutal_kill)`
  # if it doesn't return inside `timeout_ms`.
  defp do_run_codex(args, cwd, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          System.cmd(@codex_command, args,
            cd: cwd,
            stderr_to_stdout: true,
            env: review_env()
          )
        rescue
          e in ErlangError ->
            {:error_rescue, Exception.message(e)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, status}} when is_integer(status) ->
        {:error, {:codex_review_failed, status, String.trim(output)}}

      {:ok, {:error_rescue, message}} ->
        {:error, {:codex_review_unavailable, message}}

      {:exit, reason} ->
        {:error, {:codex_review_unavailable, inspect(reason)}}

      nil ->
        # Task.shutdown returned nil → it was killed mid-execution.
        {:error, {:codex_review_timeout, timeout_ms}}
    end
  end

  # Codex review uses an explicit env ALLOWLIST. Inheriting all env vars
  # and denying a few known names (MONDAY_API_TOKEN, ANTHROPIC_API_KEY) is
  # not safe enough — per-repo resolved secrets (Spec 4 §2.4
  # `repos.<key>.secrets`) inject GITHUB_TOKEN, OPENAI_API_KEY, and other
  # names that Codex's `--debug` env-echo or downstream tool calls could
  # leak. Codex itself only needs PATH/HOME/USER plus its own
  # CODEX_*-prefixed configuration; everything else is deliberately
  # withheld.
  @env_allowlist ~w(
    PATH
    HOME
    USER
    LANG
    LC_ALL
    TERM
    TMPDIR
    PWD
    XDG_CONFIG_HOME
    XDG_CACHE_HOME
    XDG_DATA_HOME
  )

  @env_allowlist_prefixes ~w(CODEX_ OPENAI_BASE_URL)

  @doc false
  @spec review_env() :: [{String.t(), String.t()}]
  def review_env do
    System.get_env()
    |> Enum.filter(fn {k, _v} -> env_var_allowed?(k) end)
  end

  @doc false
  @spec env_var_allowed?(term()) :: boolean()
  def env_var_allowed?(name) when is_binary(name) do
    name in @env_allowlist or
      Enum.any?(@env_allowlist_prefixes, &String.starts_with?(name, &1))
  end

  def env_var_allowed?(_), do: false
end
