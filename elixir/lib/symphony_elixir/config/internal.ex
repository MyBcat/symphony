defmodule SymphonyElixir.Config.Internal do
  @moduledoc false

  @doc """
  Test-only wrapper around `SymphonyElixir.Config.validate_semantics/1`.

  Exposed for the config schema test suite so semantic validation can be
  exercised against an already-parsed `Schema` struct without going through
  the full `Workflow.current/0` load. Not intended for production callers.
  """
  @spec validate_semantics_for_test(SymphonyElixir.Config.Schema.t()) :: :ok | {:error, term()}
  def validate_semantics_for_test(settings) do
    SymphonyElixir.Config.validate_semantics(settings)
  end
end
