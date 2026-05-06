defmodule SymphonyElixir.Finalizer.Shell do
  @moduledoc """
  Behaviour for the git/gh shell-out used by `SymphonyElixir.Finalizer`.

  The default implementation (`SymphonyElixir.Finalizer.Shell.Default`)
  shells out via `System.cmd/3`. Tests inject a stub via the input map's
  `:shell` key (see `SymphonyElixir.FinalizerTest.StubShell`) so the
  finalizer's decision tree is verified without spawning subprocesses.
  """

  @type cmd_result :: {:ok, String.t()} | {:error, {non_neg_integer(), String.t()} | term()}

  @callback git(args :: [String.t()], opts :: keyword()) :: cmd_result()
  @callback gh(args :: [String.t()], opts :: keyword()) :: cmd_result()
end
