defmodule SymphonyElixirWeb.ReposLiveTest do
  @moduledoc """
  Tests for ReposLive: mount + render path with per-repo health data.
  """

  use SymphonyElixir.TestSupport

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SymphonyElixirWeb.Endpoint

  defmodule ReposStaticOrchestrator do
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

  defp sample_snapshot_with_running do
    %{
      running: [
        %{
          issue_id: "issue-repo-1",
          identifier: "SYM-010",
          state: "In Progress",
          session_id: "sess-repo-1",
          turn_count: 5,
          codex_app_server_pid: nil,
          last_codex_message: nil,
          last_codex_timestamp: DateTime.utc_now(),
          last_codex_event: :turn_completed,
          codex_input_tokens: 200,
          codex_output_tokens: 100,
          codex_total_tokens: 300,
          started_at: DateTime.utc_now() |> DateTime.add(-60, :second),
          workspace_path: "/tmp/symphony-workspaces/my-repo-SYM-010"
        }
      ],
      retrying: [
        %{
          issue_id: "issue-repo-2",
          identifier: "SYM-011",
          attempt: 1,
          due_in_ms: 45_000,
          error: "exit 1",
          workspace_path: "/tmp/symphony-workspaces/other-repo-SYM-011"
        }
      ],
      codex_totals: %{input_tokens: 200, output_tokens: 100, total_tokens: 300, seconds_running: 60},
      rate_limits: nil
    }
  end

  test "mounts and renders repo health table from running sessions" do
    orch_name = Module.concat(__MODULE__, :ReposSampleOrchestrator)

    {:ok, _pid} =
      ReposStaticOrchestrator.start_link(
        name: orch_name,
        snapshot: sample_snapshot_with_running()
      )

    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos")

    assert html =~ "Repos"
    assert html =~ "my-repo-SYM-010"
    assert html =~ "other-repo-SYM-011"
    assert html =~ "active"
    assert html =~ "retrying"
  end

  test "renders empty state when no sessions exist" do
    orch_name = Module.concat(__MODULE__, :ReposEmptyOrchestrator)

    empty_snapshot = %{
      running: [],
      retrying: [],
      codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
      rate_limits: nil
    }

    {:ok, _pid} =
      ReposStaticOrchestrator.start_link(name: orch_name, snapshot: empty_snapshot)

    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 50)

    {:ok, _view, html} = live(build_conn(), "/repos")

    assert html =~ "Repos"
    assert html =~ "No repositories configured"
  end

  test "renders error state when orchestrator is unavailable" do
    orch_name = Module.concat(__MODULE__, :ReposUnavailableOrchestrator)
    start_test_endpoint(orchestrator: orch_name, snapshot_timeout_ms: 5)

    {:ok, _view, html} = live(build_conn(), "/repos")

    assert html =~ "Repos"
    assert html =~ "snapshot_unavailable"
  end
end
