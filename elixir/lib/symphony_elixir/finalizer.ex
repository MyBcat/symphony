defmodule SymphonyElixir.Finalizer do
  @moduledoc """
  M-0c-D: Symphony-side shipping finalizer for codex agent runs.

  Codex's sandbox + DNS path can block `git push` and `gh pr create` from
  inside the agent session (canary SYM-11684552415 hit `.git/index.lock`
  errors and GitHub DNS failures, then fell back to `git format-patch` —
  shipping nothing). The finalizer runs from Symphony's host process with
  the operator's real `gh auth` credentials and pushes + opens the PR
  itself, regardless of what happened inside the codex sandbox.

  See `docs/superpowers/specs/2026-05-06-symphony-codex-finalizer.md`.

  Contract (input map):
    * `:workspace` — absolute path to the issue's workspace (clone target)
    * `:issue_id` / `:issue_identifier` — Monday id and SYM-<id> identifier
    * `:issue_title` / `:issue_description` — used for PR title + body
    * `:profile_kind` — `:codex` (only kind that gets finalized in v1)
    * `:profile_name` — string for PR body
    * `:base_branch` — defaults to `"main"` if nil
    * `:shell` — `SymphonyElixir.Finalizer.Shell` impl (default
      `Finalizer.Shell.Default`); tests inject a stub

  Return:
    * `{:ok, %{pr_url: String.t(), branch: String.t()}}` on success
    * `{:noop, atom()}` or `{:noop, atom(), String.t()}` when nothing to do
    * `{:error, term()}` on failures (push rejected, gh repo view failed, etc.)

  All decisions are surfaced via the orchestrator's M-4a consolidated
  `## Symphony Run Summary`; the finalizer never writes to Monday directly.
  """

  alias SymphonyElixir.Secrets.Scrubber

  require Logger

  @sentinel "<!-- symphony-finalizer:M-0c-D -->"
  @max_title_chars 64
  @max_description_chars 1000

  @type input :: %{
          required(:workspace) => Path.t(),
          required(:issue_id) => String.t(),
          required(:issue_identifier) => String.t(),
          required(:issue_title) => String.t() | nil,
          required(:issue_description) => String.t() | nil,
          required(:profile_kind) => :codex | :claude | :gemini,
          required(:profile_name) => String.t(),
          required(:base_branch) => String.t() | nil,
          optional(:shell) => module()
        }

  @type result ::
          {:ok, %{pr_url: String.t(), branch: String.t()}}
          | {:noop, atom()}
          | {:noop, atom(), String.t()}
          | {:error, term()}

  @spec finalize(input()) :: result()
  def finalize(%{profile_kind: kind} = _input) when kind in [:claude, :gemini] do
    {:noop, :not_a_codex_profile}
  end

  def finalize(%{profile_kind: :codex} = input) do
    shell = Map.get(input, :shell, default_shell())
    base = base_branch(input)
    work_branch = work_branch_for(input)
    cwd = Map.fetch!(input, :workspace)

    with :ok <- ensure_clean_worktree(shell, cwd),
         {:ok, commits} <- count_commits(shell, cwd, base),
         :ok <- assert_has_commits(commits),
         {:ok, current_branch} <- current_branch(shell, cwd),
         :ok <- ensure_on_work_branch(shell, cwd, current_branch, work_branch, base),
         :ok <- push(shell, cwd, work_branch),
         {:ok, repo} <- gh_repo(shell, cwd),
         {:ok, maybe_pr} <- gh_existing_pr(shell, cwd, repo, work_branch) do
      case maybe_pr do
        :none ->
          create_pr(shell, cwd, repo, base, work_branch, input)

        {:found, pr_url} ->
          log_info("Finalizer noop: PR already open at #{pr_url}", input)
          {:noop, :pr_already_open, pr_url}
      end
    end
  end

  def finalize(_), do: {:error, :invalid_finalizer_input}

  # ---- decision tree helpers ----

  defp ensure_clean_worktree(shell, cwd) do
    case shell.git(["status", "--porcelain"], cd: cwd) do
      {:ok, ""} ->
        :ok

      {:ok, output} ->
        count = output |> String.split("\n", trim: true) |> length()
        {:error, {:uncommitted_changes, count}}

      {:error, reason} ->
        {:error, {:git_status_failed, scrub(reason)}}
    end
  end

  defp count_commits(shell, cwd, base) do
    case shell.git(["rev-list", "--count", "#{base}..HEAD"], cd: cwd) do
      {:ok, output} ->
        case Integer.parse(String.trim(output)) do
          {n, _} -> {:ok, n}
          :error -> {:error, {:rev_list_parse_failed, scrub(output)}}
        end

      {:error, reason} ->
        {:error, {:rev_list_failed, scrub(reason)}}
    end
  end

  defp assert_has_commits(0), do: {:noop, :no_commits}
  defp assert_has_commits(_), do: :ok

  defp current_branch(shell, cwd) do
    case shell.git(["rev-parse", "--abbrev-ref", "HEAD"], cd: cwd) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:rev_parse_failed, scrub(reason)}}
    end
  end

  defp ensure_on_work_branch(_shell, _cwd, current, want, _base) when current == want, do: :ok

  defp ensure_on_work_branch(shell, cwd, _current, want, _base) do
    case shell.git(["switch", "-C", want], cd: cwd) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:branch_switch_failed, scrub(reason)}}
    end
  end

  defp push(shell, cwd, branch) do
    case shell.git(["push", "-u", "origin", branch], cd: cwd) do
      {:ok, _} ->
        :ok

      {:error, {_status, output} = reason} ->
        if non_fast_forward?(output) do
          {:error, {:push_rejected_non_ff, branch}}
        else
          {:error, {:push_failed, scrub(reason)}}
        end

      {:error, reason} ->
        {:error, {:push_failed, scrub(reason)}}
    end
  end

  defp non_fast_forward?(output) when is_binary(output) do
    String.contains?(output, "non-fast-forward") or
      String.contains?(output, "Updates were rejected because the remote contains")
  end

  defp non_fast_forward?(_), do: false

  defp gh_repo(shell, cwd) do
    case shell.gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cd: cwd) do
      {:ok, output} ->
        repo = String.trim(output)
        if repo == "", do: {:error, {:gh_repo_view_failed, :empty_output}}, else: {:ok, repo}

      {:error, reason} ->
        {:error, {:gh_repo_view_failed, scrub(reason)}}
    end
  end

  defp gh_existing_pr(shell, cwd, repo, branch) do
    args = [
      "pr",
      "list",
      "--repo",
      repo,
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      "url",
      "--jq",
      ".[0].url // empty"
    ]

    case shell.gh(args, cd: cwd) do
      {:ok, output} ->
        case String.trim(output) do
          "" -> {:ok, :none}
          url -> {:ok, {:found, url}}
        end

      {:error, reason} ->
        {:error, {:gh_pr_list_failed, scrub(reason)}}
    end
  end

  defp create_pr(shell, cwd, repo, base, work_branch, input) do
    title = build_title(input)
    body = build_body(input)

    args = [
      "pr",
      "create",
      "--repo",
      repo,
      "--base",
      base,
      "--head",
      work_branch,
      "--title",
      title,
      "--body",
      body
    ]

    case shell.gh(args, cd: cwd) do
      {:ok, output} ->
        url = String.trim(output) |> first_url()
        log_info("Finalizer opened PR #{url} for branch #{work_branch}", input)
        {:ok, %{pr_url: url, branch: work_branch}}

      {:error, reason} ->
        {:error, {:gh_pr_create_failed, scrub(reason)}}
    end
  end

  # gh pr create may print a warning line before the URL; take the last URL
  defp first_url(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find(output, fn line -> String.starts_with?(line, "https://") end)
  end

  # ---- inputs and shaping ----

  defp default_shell do
    Application.get_env(:symphony_elixir, :finalizer_shell, SymphonyElixir.Finalizer.Shell.Default)
  end

  defp base_branch(input) do
    case Map.get(input, :base_branch) do
      v when is_binary(v) and v != "" -> v
      _ -> "main"
    end
  end

  defp work_branch_for(%{issue_identifier: id}) when is_binary(id) and id != "" do
    sanitized = String.replace(id, ~r/[^A-Za-z0-9\-_]/, "")
    "symphony/#{sanitized}/attempt-1"
  end

  defp build_title(%{issue_identifier: id, issue_title: title}) do
    safe_title =
      case title do
        v when is_binary(v) and v != "" -> v
        _ -> "(no title)"
      end

    truncated =
      if String.length(safe_title) > @max_title_chars do
        String.slice(safe_title, 0, @max_title_chars)
      else
        safe_title
      end

    "#{id}: #{truncated}"
  end

  defp build_body(input) do
    desc =
      case Map.get(input, :issue_description) do
        v when is_binary(v) and v != "" -> truncate(v, @max_description_chars)
        _ -> "(no description provided)"
      end

    [
      "Closes Monday item ",
      Map.fetch!(input, :issue_identifier),
      ".\n",
      "Symphony profile: ",
      Map.fetch!(input, :profile_name),
      ".\n\n",
      desc,
      "\n\n",
      @sentinel
    ]
    |> IO.iodata_to_binary()
  end

  defp truncate(s, n) do
    if String.length(s) > n, do: String.slice(s, 0, n), else: s
  end

  # ---- logging + scrubbing ----

  defp scrub({status, output}) when is_integer(status) and is_binary(output) do
    {status, Scrubber.scrub(output)}
  end

  defp scrub(reason) when is_binary(reason), do: Scrubber.scrub(reason)
  defp scrub(reason), do: reason

  defp log_info(msg, %{issue_identifier: id}) do
    Logger.info("[Finalizer #{id}] #{Scrubber.scrub(msg)}")
  end

  defp log_info(msg, _), do: Logger.info("[Finalizer] #{Scrubber.scrub(msg)}")
end
