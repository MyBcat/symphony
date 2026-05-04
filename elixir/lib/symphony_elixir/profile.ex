defmodule SymphonyElixir.Profile do
  @moduledoc """
  Named bundle of agent runtime kind + per-kind config + optional concurrency cap.
  Profiles are defined in WORKFLOW.md and resolved per-issue via the Monday
  Symphony Profile dropdown column (or fall back to agent.default_profile).
  """

  @type kind :: :codex | :claude | :gemini

  @type t :: %__MODULE__{
          name: String.t(),
          kind: kind(),
          max_concurrent: pos_integer() | nil,
          config: map()
        }

  defstruct [:name, :kind, :max_concurrent, :config]

  @secret_patterns [
    ~r/(?i)(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|GEMINI_API_KEY|MONDAY_API_TOKEN)\s*=\s*['"]?([A-Za-z0-9_\-\.]+)['"]?/,
    ~r/sk-proj-[A-Za-z0-9_\-]+/,
    ~r/sk-[A-Za-z0-9_\-]{16,}/
  ]

  @spec redact_command(String.t() | nil) :: String.t() | nil
  def redact_command(nil), do: nil

  def redact_command(command) when is_binary(command) do
    Enum.reduce(@secret_patterns, command, fn pattern, acc ->
      Regex.replace(pattern, acc, "<redacted-secret-fragment>")
    end)
  end
end

defimpl Inspect, for: SymphonyElixir.Profile do
  def inspect(profile, opts) do
    redacted_config = redact_config(profile.config)

    redacted = %{profile | config: redacted_config}
    Inspect.Any.inspect(redacted, opts)
  end

  defp redact_config(config) when is_map(config) do
    cond do
      Map.has_key?(config, :command) ->
        Map.update!(config, :command, &SymphonyElixir.Profile.redact_command/1)

      Map.has_key?(config, "command") ->
        Map.update!(config, "command", &SymphonyElixir.Profile.redact_command/1)

      true ->
        config
    end
  end

  defp redact_config(config), do: config
end
