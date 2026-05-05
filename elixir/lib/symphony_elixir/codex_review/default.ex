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

  defp cwd_for_exec(cwd) when is_binary(cwd) and cwd != "" do
    case File.dir?(cwd) do
      true -> cwd
      false -> System.tmp_dir!()
    end
  end

  defp cwd_for_exec(_), do: System.tmp_dir!()

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

  defp do_run_codex(args, cwd, _timeout_ms) do
    case System.cmd(@codex_command, args,
           cd: cwd,
           stderr_to_stdout: true,
           env: review_env()
         ) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, {:codex_review_failed, status, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:codex_review_unavailable, Exception.message(e)}}
  end

  # Codex review must NOT inherit MONDAY_API_TOKEN or any per-repo resolved
  # secrets — the review itself doesn't need them and removing them defends
  # against accidental log leaks if Codex echoes its env. Inherit the
  # operator's PATH and HOME so the binary can find its config.
  defp review_env do
    base = System.get_env() |> Map.new()

    Enum.reduce(["MONDAY_API_TOKEN", "ANTHROPIC_API_KEY"], base, fn key, env ->
      Map.delete(env, key)
    end)
    |> Map.to_list()
  end
end
