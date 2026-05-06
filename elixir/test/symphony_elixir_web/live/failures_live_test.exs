defmodule SymphonyElixirWeb.FailuresLiveTest do
  @moduledoc """
  Tests for FailuresLive: mount + render path with sample failure data.
  """

  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule FailuresStaticOrchestrator do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def init(opts), do: {:ok, opts}

    def handle_call(:snapshot, _from, state) do
      {:reply, Keyword.fetch!(state, :snapshot), state}
    end

    def handle_call(:request_refresh, _from, state) do
      {:reply, :unavailable, state}
    end
  end

  defp start_test_endpoint(overrides) do
    endpoint_config =
      :symphony_elixir
      |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
      |> Keyword.merge(server: false, secret_key_base: String.duplicate("s", 64))
      |> Keyword.merge(overrides)

    Application.put_env(:symphony_elixir, SymphonyElixirWeb.Endpoint, endpoint_config)
    start_supervised!({SymphonyElixirWeb.Endpoint, []})
  end

  defp sample_snapshot_with_failures do
    %{
      running: [],
      retrying: [
        %{
          issue_id: "issue-fail-1",
          identifier: "SYM-002",
          attempt: 2,
          due_in_ms: 60_000,
          error: "Process exited with exit code 1\nstderr: command not found"
        },
        %{
          issue_id: "issue-fail-2",
          identifier: "SYM-003",
          attempt: 1,
          due_in_ms: 30_000,
          error: "Process exited with exit_code 2\nsome other error"
        }
      ],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }
  end

  test "mounts and renders failure list with sample data" do
    orch_name = Module.concat(__MODULE__, :FailuresSampleOrchestrator)

    {:ok, _pid} =
      FailuresStaticOrchestrator.start_link(
        name: orch_name,
        snapshot: sample_snapshot_with_failures()
      )

    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/failures")

    assert html =~ "Failures"
    assert html =~ "SYM-002"
    assert html =~ "SYM-003"
    assert html =~ "exit 1"
    assert html =~ "command not found"
  end

  test "shows empty state when no failures exist" do
    orch_name = Module.concat(__MODULE__, :FailuresEmptyOrchestrator)

    empty_snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} =
      FailuresStaticOrchestrator.start_link(name: orch_name, snapshot: empty_snapshot)

    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/failures")

    assert html =~ "Failures"
    assert html =~ "No failures recorded"
  end

  test "renders error state when orchestrator is unavailable" do
    orch_name = Module.concat(__MODULE__, :FailuresUnavailableOrchestrator)
    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/failures")

    assert html =~ "Failures"
    assert html =~ "snapshot_unavailable"
  end

  test "displays max_failures count in page copy" do
    orch_name = Module.concat(__MODULE__, :FailuresMaxOrchestrator)

    empty_snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} =
      FailuresStaticOrchestrator.start_link(name: orch_name, snapshot: empty_snapshot)

    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/failures")

    assert html =~ "50"
  end
end
