defmodule SymphonyElixir.Finalizer.Shell.Default do
  @moduledoc """
  Default `SymphonyElixir.Finalizer.Shell` implementation. Shells out via
  `System.cmd/3` for git and gh CLIs.

  Per the M-0c-D spec, all shell-outs run for at most 30 seconds and use
  the workspace path as `:cd`. Stderr is folded into stdout so we can
  scrub it via `Secrets.Scrubber` before logging or returning to the
  caller.
  """

  @behaviour SymphonyElixir.Finalizer.Shell

  alias SymphonyElixir.Secrets.Scrubber

  require Logger

  @timeout_ms 30_000
  @git_bin_key :finalizer_git_bin
  @gh_bin_key :finalizer_gh_bin

  @impl true
  def git(args, opts) when is_list(args) do
    bin = Application.get_env(:symphony_elixir, @git_bin_key, "git")
    run(bin, args, opts)
  end

  @impl true
  def gh(args, opts) when is_list(args) do
    bin = Application.get_env(:symphony_elixir, @gh_bin_key, "gh")
    run(bin, args, opts)
  end

  defp run(bin, args, opts) do
    cwd = Keyword.get(opts, :cd, File.cwd!())

    task =
      Task.async(fn ->
        try do
          System.cmd(bin, args, cd: cwd, stderr_to_stdout: true)
        rescue
          e in ErlangError -> {:exception, e}
          e -> {:exception, e}
        end
      end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        scrubbed = Scrubber.scrub(output)
        Logger.debug("Finalizer #{bin} #{Enum.join(args, " ")}: ok")
        {:ok, scrubbed}

      {:ok, {output, status}} when is_integer(status) ->
        scrubbed = Scrubber.scrub(output)
        Logger.warning("Finalizer #{bin} #{Enum.join(args, " ")}: exit=#{status}")
        {:error, {status, scrubbed}}

      {:ok, {:exception, e}} ->
        Logger.warning("Finalizer #{bin} raised: #{inspect(e)}")
        {:error, {:exception, e}}

      nil ->
        Logger.warning("Finalizer #{bin} timed out after #{@timeout_ms}ms")
        {:error, :timeout}
    end
  end
end
