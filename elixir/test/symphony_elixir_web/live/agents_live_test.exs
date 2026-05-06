defmodule SymphonyElixirWeb.AgentsLiveTest do
  @moduledoc """
  Tests for AgentsLive: mount + render path with sample telemetry data.
  """

  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule AgentsStaticOrchestrator do
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

  defp sample_snapshot do
    %{
      running: [
        %{
          issue_id: "issue-agent-1",
          identifier: "SYM-001",
          state: "In Progress",
          session_id: "sess-abc",
          turn_count: 3,
          codex_app_server_pid: nil,
          last_codex_message: nil,
          last_codex_timestamp: nil,
          last_codex_event: :turn_completed,
          codex_input_tokens: 1_000,
          codex_output_tokens: 500,
          codex_total_tokens: 1_500,
          started_at: DateTime.utc_now() |> DateTime.add(-120, :second),
          workspace_path: "/tmp/symphony-workspaces/my-repo-SYM-001"
        }
      ],
      retrying: [],
      codex_totals: %{
        input_tokens: 1_000,
        output_tokens: 500,
        total_tokens: 1_500,
        seconds_running: 120
      },
      rate_limits: nil
    }
  end

  test "mounts and renders agent list with sample data" do
    orch_name = Module.concat(__MODULE__, :AgentsSampleOrchestrator)
    {:ok, _pid} = AgentsStaticOrchestrator.start_link(name: orch_name, snapshot: sample_snapshot())
    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/agents")

    assert html =~ "Live Agents"
    assert html =~ "SYM-001"
    assert html =~ "my-repo-SYM-001"
    assert html =~ "1,500"
    assert html =~ "turn_completed"
  end

  test "shows nav links to all dashboard pages" do
    orch_name = Module.concat(__MODULE__, :AgentsNavOrchestrator)
    {:ok, _pid} = AgentsStaticOrchestrator.start_link(name: orch_name, snapshot: sample_snapshot())
    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/agents")

    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/agents")
    assert html =~ ~s(href="/failures")
    assert html =~ ~s(href="/repos")
  end

  test "renders empty state when no agents are running" do
    orch_name = Module.concat(__MODULE__, :AgentsEmptyOrchestrator)

    empty_snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} = AgentsStaticOrchestrator.start_link(name: orch_name, snapshot: empty_snapshot)
    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/agents")

    assert html =~ "Live Agents"
    assert html =~ "No active agents"
  end

  test "renders error state when orchestrator is unavailable" do
    orch_name = Module.concat(__MODULE__, :AgentsUnavailableOrchestrator)
    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/agents")

    assert html =~ "Live Agents"
    assert html =~ "snapshot_unavailable"
  end
end
