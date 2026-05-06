defmodule SymphonyElixir.PRSafety.GH.Default do
  @moduledoc """
  Default `SymphonyElixir.PRSafety.GH` implementation. Shells out to the `gh`
  CLI on the operator's host. Authentication is the operator's responsibility
  — Symphony does not manage `gh auth` state.
  """

  @behaviour SymphonyElixir.PRSafety.GH

  @gh_command "gh"
  @pull_url_regex ~r{^https://github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)(?:\b|/)?$}

  @impl true
  def pr_view_basic(url) when is_binary(url) do
    args = ["pr", "view", url, "--json", "baseRefName,headRefName,url,headRefOid"]

    case run_gh(args) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok,
           %{
             "baseRefName" => base,
             "headRefName" => head,
             "url" => out_url,
             "headRefOid" => head_sha
           }}
          when is_binary(base) and is_binary(head) and is_binary(out_url) and
                 is_binary(head_sha) and head_sha != "" ->
            {:ok,
             %{
               base_branch: base,
               head_branch: head,
               url: out_url,
               head_sha: head_sha
             }}

          {:ok, _other} ->
            {:error, {:unexpected_gh_payload, :missing_fields}}

          {:error, reason} ->
            {:error, {:gh_decode_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def pr_head_contains_sha(url, prior_sha)
      when is_binary(url) and is_binary(prior_sha) and prior_sha != "" do
    with {:ok, {owner, repo, _number}} <- parse_pull_url(url),
         {:ok, %{head_sha: head_sha}} <- pr_view_basic(url) do
      if head_sha == prior_sha do
        {:ok, true}
      else
        compare_head_to_prior(owner, repo, prior_sha, head_sha)
      end
    end
  end

  def pr_head_contains_sha(_url, _prior_sha), do: {:error, :invalid_prior_sha}

  defp parse_pull_url(url) do
    case Regex.run(@pull_url_regex, url) do
      [_full, owner, repo, number] ->
        {:ok, {owner, repo, number}}

      _ ->
        {:error, {:invalid_pr_url, url}}
    end
  end

  defp compare_head_to_prior(owner, repo, prior_sha, head_sha) do
    path = "repos/#{owner}/#{repo}/compare/#{prior_sha}...#{head_sha}"

    case run_gh(["api", path, "--jq", ".status"]) do
      {:ok, status} ->
        compare_status_contains_prior(String.trim(status))

      {:error, {:gh_failed, _status, output}} = err ->
        if String.contains?(output, "HTTP 404") do
          {:ok, false}
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

  defp compare_status_contains_prior("ahead"), do: {:ok, true}
  defp compare_status_contains_prior("identical"), do: {:ok, true}
  defp compare_status_contains_prior("behind"), do: {:ok, false}
  defp compare_status_contains_prior("diverged"), do: {:ok, false}

  defp compare_status_contains_prior(other),
    do: {:error, {:unexpected_gh_payload, {:compare_status, other}}}

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
