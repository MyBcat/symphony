defmodule SymphonyElixir.AutoMerge.GH.Default do
  @moduledoc """
  Default `SymphonyElixir.AutoMerge.GH` implementation. Shells out to the
  `gh` CLI on the operator's host. Authentication is the operator's
  responsibility — Symphony does not manage `gh auth` state.
  """

  @behaviour SymphonyElixir.AutoMerge.GH

  @gh_command "gh"

  @impl true
  def pr_diff_line_count(url) when is_binary(url) and url != "" do
    case run_gh(["pr", "diff", url]) do
      {:ok, body} ->
        # Match `gh pr diff | wc -l` semantics: count the number of '\n'
        # bytes. A trailing line with no newline is not counted, matching
        # POSIX `wc -l`.
        count = body |> :binary.matches("\n") |> length()

        {:ok, count}

      {:error, _} = err ->
        err
    end
  end

  def pr_diff_line_count(_), do: {:error, :invalid_pr_url}

  @impl true
  def pr_view_base(url) when is_binary(url) and url != "" do
    case run_gh(["pr", "view", url, "--json", "baseRefName"]) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"baseRefName" => base}} when is_binary(base) ->
            {:ok, base}

          {:ok, _} ->
            {:error, {:unexpected_gh_payload, :missing_base_ref}}

          {:error, reason} ->
            {:error, {:gh_decode_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  def pr_view_base(_), do: {:error, :invalid_pr_url}

  @impl true
  def pr_merge(url) when is_binary(url) and url != "" do
    # Spec 4 §2.8a: --merge only (no squash/rebase). --auto enables GitHub's
    # auto-merge so checks can finalize before the merge lands.
    case run_gh(["pr", "merge", url, "--merge", "--auto"]) do
      {:ok, _output} -> :ok
      {:error, _} = err -> err
    end
  end

  def pr_merge(_), do: {:error, :invalid_pr_url}

  defp run_gh(args) do
    case System.cmd(@gh_command, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output}

      {output, status} ->
        {:error, {:gh_failed, status, String.trim(output)}}
    end
  rescue
    e in ErlangError ->
      {:error, {:gh_unavailable, Exception.message(e)}}
  end
end
