defmodule SymphonyElixir.PRSafety.GH do
  @moduledoc """
  Behaviour wrapping the `gh` CLI calls used by `SymphonyElixir.PRSafety`.

  The default implementation (`SymphonyElixir.PRSafety.GH.Default`) shells out
  via `System.cmd/3`. Tests inject a stub via `Application.put_env/3` under
  `:pr_safety_gh_module` so the PR safety pipeline is exercisable without a
  live `gh` binary or GitHub auth.
  """

  @typedoc """
  Result of a `gh pr view --json baseRefName,headRefName,url` call.

  `head_sha` is populated by an additional `--json` field (`headRefOid`) when
  the production caller fetches branch metadata in the same call. Tests can
  populate it directly.
  """
  @type pr_basic :: %{
          base_branch: String.t(),
          head_branch: String.t(),
          url: String.t(),
          head_sha: String.t()
        }

  @callback pr_view_basic(String.t()) :: {:ok, pr_basic()} | {:error, term()}
  @callback pr_head_contains_sha(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}

  @doc """
  Resolve the configured GH module — either the default `System.cmd/3` impl
  or a test-injected stub.
  """
  @spec module() :: module()
  def module do
    Application.get_env(:symphony_elixir, :pr_safety_gh_module, __MODULE__.Default)
  end

  @spec pr_view_basic(String.t()) :: {:ok, pr_basic()} | {:error, term()}
  def pr_view_basic(url), do: module().pr_view_basic(url)

  @spec pr_head_contains_sha(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def pr_head_contains_sha(url, sha), do: module().pr_head_contains_sha(url, sha)
end
