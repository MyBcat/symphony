defmodule SymphonyElixir.ProfileTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Profile

  test "Profile struct has kind, name, max_concurrent, and per-kind config" do
    profile = %Profile{
      name: "claude_opus",
      kind: :claude,
      max_concurrent: 2,
      config: %{
        command: "claude --print --output-format stream-json",
        model: "claude-opus-4-7",
        permission_mode: "acceptEdits"
      }
    }

    assert profile.name == "claude_opus"
    assert profile.kind == :claude
    assert profile.max_concurrent == 2
  end

  test "Profile inspect redacts command strings containing token patterns" do
    profile = %Profile{
      name: "codex_with_secret",
      kind: :codex,
      max_concurrent: nil,
      config: %{
        command: "codex --config 'OPENAI_API_KEY=sk-proj-abc123' app-server"
      }
    }

    rendered = inspect(profile)
    refute rendered =~ "sk-proj-abc123"
    assert rendered =~ "<redacted-secret-fragment>"
  end

  test "Profile inspect leaves non-secret commands intact" do
    profile = %Profile{
      name: "claude_opus",
      kind: :claude,
      max_concurrent: 2,
      config: %{
        command: "claude --print --output-format stream-json --model claude-opus-4-7"
      }
    }

    rendered = inspect(profile)
    assert rendered =~ "claude --print"
    assert rendered =~ "claude-opus-4-7"
  end
end
