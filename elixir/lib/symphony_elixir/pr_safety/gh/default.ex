defmodule SymphonyElixir.PRSafety.GH.Default do
  @moduledoc """
  Default `SymphonyElixir.PRSafety.GH` implementation. Shells out to the `gh`
  CLI on the operator's host. Authentication is the operator's responsibility
  — Symphony does not manage `gh auth` state.
  """

  @behaviour SymphonyElixir.PRSafety.GH

  @gh_command "gh"

  @impl true
  def pr_view_basic(url) when is_binary(url) do
    args = ["pr", "view", url, "--json", "baseRefName,headRefName,url,headRefOid"]

    case run_gh(args) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"baseRefName" => base, "headRefName" => head, "url" => out_url} = map}
          when is_binary(base) and is_binary(head) and is_binary(out_url) ->
            {:ok,
             %{
               base_branch: base,
               head_branch: head,
               url: out_url,
               head_sha: stringify_sha(Map.get(map, "headRefOid"))
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
  def pr_view_commits(url) when is_binary(url) do
    args = ["pr", "view", url, "--json", "commits"]

    case run_gh(args) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"commits" => commits}} when is_list(commits) ->
            {:ok, Enum.map(commits, &normalize_commit/1)}

          {:ok, _other} ->
            {:error, {:unexpected_gh_payload, :missing_commits}}

          {:error, reason} ->
            {:error, {:gh_decode_failed, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

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

  defp normalize_commit(%{"oid" => oid}) when is_binary(oid), do: %{sha: oid}
  defp normalize_commit(%{"sha" => sha}) when is_binary(sha), do: %{sha: sha}
  defp normalize_commit(_), do: %{sha: ""}

  defp stringify_sha(nil), do: ""
  defp stringify_sha(value) when is_binary(value), do: value
  defp stringify_sha(_), do: ""
end
