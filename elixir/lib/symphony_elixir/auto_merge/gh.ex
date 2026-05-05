defmodule SymphonyElixir.AutoMerge.GH do
  @moduledoc """
  Behaviour wrapping the `gh` CLI calls used by `SymphonyElixir.AutoMerge`
  to size the diff, fetch the base branch, and run the auto-merge action.

  The default implementation (`SymphonyElixir.AutoMerge.GH.Default`) shells
  out via `System.cmd/3`. Tests inject a stub via
  `Application.put_env(:symphony_elixir, :auto_merge_gh_module, MyStub)`.

  Distinct from `SymphonyElixir.PRSafety.GH`: the PR-safety behaviour is
  read-only (`pr view`, `compare`); this one performs the write action
  (`pr merge`).
  """

  @callback pr_diff_line_count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  @callback pr_view_base(String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback pr_merge(String.t()) :: :ok | {:error, term()}

  @spec module() :: module()
  def module do
    Application.get_env(:symphony_elixir, :auto_merge_gh_module, __MODULE__.Default)
  end

  @spec pr_diff_line_count(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def pr_diff_line_count(url), do: module().pr_diff_line_count(url)

  @spec pr_view_base(String.t()) :: {:ok, String.t()} | {:error, term()}
  def pr_view_base(url), do: module().pr_view_base(url)

  @spec pr_merge(String.t()) :: :ok | {:error, term()}
  def pr_merge(url), do: module().pr_merge(url)
end
