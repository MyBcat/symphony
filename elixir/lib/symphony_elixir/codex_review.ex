defmodule SymphonyElixir.CodexReview do
  @moduledoc """
  Behaviour wrapping the `codex exec` CLI invocation that runs an
  unattended Codex review against a freshly opened PR (Spec 4 §2.8a).

  The default implementation (`SymphonyElixir.CodexReview.Default`) shells
  out via `System.cmd/3`. Tests inject a stub via
  `Application.put_env(:symphony_elixir, :codex_review_module, MyStub)` so
  `AutoMerge` is exercisable without a live codex binary or network.

  Output is the full Codex stdout/stderr capture, scrubbed for secrets and
  PHI before it reaches Workpad / disk_log per Spec 4 §2.4 / §2.5.
  """

  @typedoc """
  Inputs for a single review run. `prompt` is the canonical review prompt
  rendered by `SymphonyElixir.AutoMerge.build_prompt/1`. `cwd` may be the
  agent workspace path (when available at PR-detection time) or any other
  directory that Codex can launch from. `profile_config` is the resolved
  `codex_gpt55_xhigh` profile config (raw map from
  `SymphonyElixir.Profile.config/0`).
  """
  @type input :: %{
          required(:prompt) => String.t(),
          required(:cwd) => Path.t() | nil,
          required(:profile_config) => map()
        }

  @callback review(input()) :: {:ok, String.t()} | {:error, term()}

  @doc "Resolve the configured runner — either default or a test stub."
  @spec module() :: module()
  def module do
    Application.get_env(:symphony_elixir, :codex_review_module, __MODULE__.Default)
  end

  @spec review(input()) :: {:ok, String.t()} | {:error, term()}
  def review(%{prompt: _, cwd: _, profile_config: _} = input), do: module().review(input)
end
