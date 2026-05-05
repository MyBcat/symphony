defmodule SymphonyElixir.CodexReviewTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.CodexReview

  defmodule StubRunner do
    @moduledoc false
    @behaviour SymphonyElixir.CodexReview

    @impl true
    def review(input) do
      Process.put({__MODULE__, :last_input}, input)

      case Process.get({__MODULE__, :review_response}) do
        nil -> {:ok, "stub: NO BLOCKING ISSUES"}
        response -> response
      end
    end

    def stub_review(response), do: Process.put({__MODULE__, :review_response}, response)
    def last_input, do: Process.get({__MODULE__, :last_input})
  end

  setup do
    Application.put_env(:symphony_elixir, :codex_review_module, StubRunner)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :codex_review_module)
    end)

    :ok
  end

  describe "review/1 — dispatch" do
    test "delegates to the configured module" do
      input = %{
        prompt: "Scrutinize PR 42",
        cwd: "/tmp",
        profile_config: %{"model" => "gpt-5.5"}
      }

      assert {:ok, "stub: NO BLOCKING ISSUES"} = CodexReview.review(input)
      assert StubRunner.last_input() == input
    end

    test "propagates runner errors" do
      StubRunner.stub_review({:error, :stub_unavailable})

      assert {:error, :stub_unavailable} =
               CodexReview.review(%{prompt: "p", cwd: nil, profile_config: %{}})
    end
  end

  describe "Default env safety (Spec 4 §2.8a M-2)" do
    test "review_env allowlist includes PATH/HOME/USER but excludes secret-bearing env vars" do
      previous = Map.new(System.get_env())

      try do
        # Set a few env vars representative of the inputs the operator's
        # shell normally exports plus the per-repo resolved secrets we
        # MUST NOT propagate to the codex CLI.
        System.put_env("PATH", previous["PATH"] || "/usr/bin")
        System.put_env("HOME", previous["HOME"] || "/tmp")
        System.put_env("USER", previous["USER"] || "test")
        System.put_env("MONDAY_API_TOKEN", "monday-secret-test-value")
        System.put_env("GITHUB_TOKEN", "ghp_should_not_propagate_test")
        System.put_env("OPENAI_API_KEY", "sk-leaked-key-test")
        System.put_env("ANTHROPIC_API_KEY", "sk-ant-leaked-test")

        env = SymphonyElixir.CodexReview.Default.review_env()
        env_map = Map.new(env)

        assert Map.has_key?(env_map, "PATH")
        assert Map.has_key?(env_map, "HOME")

        refute Map.has_key?(env_map, "MONDAY_API_TOKEN")
        refute Map.has_key?(env_map, "GITHUB_TOKEN")
        refute Map.has_key?(env_map, "OPENAI_API_KEY")
        refute Map.has_key?(env_map, "ANTHROPIC_API_KEY")
      after
        # Restore env to whatever it was before (best-effort — clearing
        # added keys + restoring originals).
        for key <- ["MONDAY_API_TOKEN", "GITHUB_TOKEN", "OPENAI_API_KEY", "ANTHROPIC_API_KEY"] do
          case Map.get(previous, key) do
            nil -> System.delete_env(key)
            value -> System.put_env(key, value)
          end
        end
      end
    end
  end

  describe "Default.build_args/2" do
    test "renders codex exec --skip-git-repo-check + model + reasoning_effort + prompt" do
      args =
        SymphonyElixir.CodexReview.Default.build_args("p", %{
          "model" => "gpt-5.5",
          "reasoning_effort" => "xhigh"
        })

      assert "exec" in args
      assert "--skip-git-repo-check" in args
      assert ~s(model="gpt-5.5") in args
      assert "model_reasoning_effort=xhigh" in args
      assert List.last(args) == "p"
    end

    test "falls back to default model when missing from profile_config" do
      args = SymphonyElixir.CodexReview.Default.build_args("p", %{})

      assert ~s(model="gpt-5.5") in args
      assert "model_reasoning_effort=xhigh" in args
    end

    test "supports atom keys" do
      args = SymphonyElixir.CodexReview.Default.build_args("p", %{model: "claude-haiku"})

      assert ~s(model="claude-haiku") in args
    end
  end
end
