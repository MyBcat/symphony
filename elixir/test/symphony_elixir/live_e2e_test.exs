defmodule SymphonyElixir.LiveE2ETest do
  @moduledoc """
  Live end-to-end test against the real Monday.com GraphQL API.

  Lifecycle:
    1. Create a disposable Monday board (private, named `Symphony E2E <ts>`).
    2. Create the Symphony columns (`Symphony Status` status; `Symphony PR` link).
    3. Create a heartbeat sentinel item.
    4. Write a temporary WORKFLOW.md pointing at the disposable board.
    5. Boot Symphony with that WORKFLOW.md.
    6. Create one item with `Symphony Status = Symphony Ready`.
    7. Wait for the orchestrator to dispatch and verify Symphony-side writes:
         - Symphony wrote `In Progress` on the status column.
         - A `## Symphony Workpad` Update appeared on the item.
    8. Tear down: archive the disposable board.

  Skipped unless `SYMPHONY_RUN_LIVE_E2E=1` AND `MONDAY_API_TOKEN` is set.
  """

  use ExUnit.Case, async: false

  require Logger

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Monday.Client
  alias SymphonyElixir.SSH
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @moduletag :live_e2e
  @moduletag timeout: 600_000

  @docker_worker_count 2
  @docker_support_dir Path.expand("../support/live_e2e_docker", __DIR__)
  @docker_compose_file Path.join(@docker_support_dir, "docker-compose.yml")
  @default_docker_auth_json Path.join(System.user_home!(), ".codex/auth.json")

  @live_e2e_skip_reason (cond do
                           System.get_env("SYMPHONY_RUN_LIVE_E2E") != "1" ->
                             "set SYMPHONY_RUN_LIVE_E2E=1 to enable the real Monday/Codex end-to-end test"

                           is_nil(System.get_env("MONDAY_API_TOKEN")) or
                               System.get_env("MONDAY_API_TOKEN") == "" ->
                             "set MONDAY_API_TOKEN to enable the real Monday/Codex end-to-end test"

                           true ->
                             nil
                         end)

  # --- canonical Symphony status labels (kept aligned with Monday adapter defaults) ---
  @symphony_status_labels [
    "Symphony Ready",
    "In Progress",
    "Human Review",
    "Merging",
    "Rework",
    "Done",
    "Cancelled"
  ]

  @active_states ["Symphony Ready", "In Progress", "Rework"]
  @handoff_states ["Human Review", "Merging"]
  @terminal_states ["Done", "Cancelled"]

  # --- Monday GraphQL operations (inline; pragmatic per Spec 1 task scope) ---

  @create_board_mutation """
  mutation SymphonyE2ECreateBoard($name: String!) {
    create_board(board_name: $name, board_kind: private) {
      id
    }
  }
  """

  @create_column_mutation """
  mutation SymphonyE2ECreateColumn($boardId: ID!, $title: String!, $type: ColumnType!, $defaults: JSON) {
    create_column(board_id: $boardId, title: $title, column_type: $type, defaults: $defaults) {
      id
      title
    }
  }
  """

  @create_item_mutation """
  mutation SymphonyE2ECreateItem($boardId: ID!, $name: String!, $columnValues: JSON) {
    create_item(board_id: $boardId, item_name: $name, column_values: $columnValues) {
      id
      name
    }
  }
  """

  @archive_board_mutation """
  mutation SymphonyE2EArchiveBoard($boardId: ID!) {
    archive_board(board_id: $boardId) {
      id
    }
  }
  """

  @item_status_query """
  query SymphonyE2EItemStatus($itemId: ID!, $columnIds: [String!]) {
    items(ids: [$itemId]) {
      id
      name
      column_values(ids: $columnIds) {
        id
        text
      }
      updates(limit: 25) {
        id
        body
      }
    }
  }
  """

  @tag skip: @live_e2e_skip_reason
  test "Symphony drives a disposable Monday board with a local worker" do
    run_live_monday_flow!(:local)
  end

  @tag skip: @live_e2e_skip_reason
  test "Symphony drives a disposable Monday board with an ssh worker" do
    run_live_monday_flow!(:ssh)
  end

  # --- main flow ---

  defp run_live_monday_flow!(backend) when backend in [:local, :ssh] do
    run_id = "symphony-live-e2e-monday-#{backend}-#{System.unique_integer([:positive])}"
    test_root = Path.join(System.tmp_dir!(), run_id)
    workflow_root = Path.join(test_root, "workflow")
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    File.mkdir_p!(workflow_root)

    worker_setup = live_worker_setup!(backend, run_id, test_root)
    original_workflow_path = Workflow.workflow_file_path()
    orchestrator_pid = Process.whereis(SymphonyElixir.Orchestrator)

    # Track the board id in a process dictionary slot so the `after` block can read
    # it without an unused-variable warning when assignment happens mid-flow.
    Process.put(:live_e2e_board_id, nil)

    try do
      if is_pid(orchestrator_pid) do
        assert :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator)
      end

      # 1. Disposable board.
      board_id = create_disposable_board!(backend)
      Process.put(:live_e2e_board_id, board_id)

      # 2. Three Symphony columns.
      symphony_status_column_id =
        create_column!(board_id, "Symphony Status", "status", status_defaults_json(@symphony_status_labels))

      symphony_pr_column_id = create_column!(board_id, "Symphony PR", "link", nil)

      # 3. Heartbeat sentinel item.
      heartbeat_item_id =
        create_item!(board_id, "[Symphony Heartbeat — DO NOT EDIT]", %{})

      # 4. Disposable WORKFLOW.md pointing at this board.
      Workflow.set_workflow_file_path(workflow_file)

      write_monday_workflow_file!(workflow_file,
        board_id: board_id,
        symphony_status_column_id: symphony_status_column_id,
        pr_column_id: symphony_pr_column_id,
        heartbeat_item_id: heartbeat_item_id,
        workspace_root: worker_setup.workspace_root,
        worker_ssh_hosts: worker_setup.ssh_worker_hosts,
        codex_command: worker_setup.codex_command
      )

      reload_workflow_store()

      # 5. Boot Symphony (real Monday.Adapter via tracker.kind=monday).
      Application.delete_env(:symphony_elixir, :tracker_adapter_override)

      # 6. Create a disposable item with Symphony Ready.
      column_values = %{
        symphony_status_column_id => %{"label" => "Symphony Ready"}
      }

      item_id = create_item!(board_id, "Symphony E2E #{backend} item", column_values)

      issue =
        %Issue{
          id: item_id,
          identifier: "SYM-#{item_id}",
          title: "Symphony E2E #{backend} item",
          description: "Live e2e disposable item",
          state: "Symphony Ready",
          url: nil,
          labels: [],
          blocked_by: []
        }

      # 7. Wait for Symphony to dispatch — assert Symphony-side writes.
      #
      # Per Spec 1 DL-005, AgentRunner exercises the Tracker primitive directly;
      # the orchestrator owns the polling loop, but for a deterministic E2E we
      # invoke the runner once and then poll Monday for the resulting writes.
      assert :ok = AgentRunner.run(issue, self(), max_turns: 3)

      assert wait_until_status_is(item_id, symphony_status_column_id, "In Progress", 30_000),
             "expected Symphony to write status='In Progress' on item #{item_id}"

      assert wait_until_workpad_present(item_id, 30_000),
             "expected Symphony to post a `## Symphony Workpad` Update on item #{item_id}"
    after
      restart_orchestrator_if_needed()
      cleanup_live_worker_setup(worker_setup)
      Workflow.set_workflow_file_path(original_workflow_path)
      reload_workflow_store()
      _ = archive_board_safe(Process.get(:live_e2e_board_id))
      Process.delete(:live_e2e_board_id)
      File.rm_rf(test_root)
    end
  end

  # --- Monday GraphQL helpers (real API; bare-token auth via Client.graphql/3) ---

  defp create_disposable_board!(backend) do
    name = "Symphony E2E #{backend} #{System.system_time(:second)}"

    @create_board_mutation
    |> graphql_data!(%{"name" => name})
    |> get_in(["create_board", "id"])
    |> case do
      nil -> flunk("expected create_board to return an id, got nil")
      id when is_binary(id) -> id
      id -> to_string(id)
    end
  end

  defp create_column!(board_id, title, type, defaults_json) do
    vars = %{"boardId" => board_id, "title" => title, "type" => type, "defaults" => defaults_json}

    @create_column_mutation
    |> graphql_data!(vars)
    |> get_in(["create_column", "id"])
    |> case do
      nil -> flunk("expected create_column to return an id, got nil for #{title}")
      id -> to_string(id)
    end
  end

  defp create_item!(board_id, name, column_values) when is_map(column_values) do
    vars = %{
      "boardId" => board_id,
      "name" => name,
      "columnValues" => Jason.encode!(column_values)
    }

    @create_item_mutation
    |> graphql_data!(vars)
    |> get_in(["create_item", "id"])
    |> case do
      nil -> flunk("expected create_item to return an id, got nil for #{name}")
      id -> to_string(id)
    end
  end

  defp archive_board_safe(nil), do: :ok

  defp archive_board_safe(board_id) when is_binary(board_id) do
    case Client.graphql(@archive_board_mutation, %{"boardId" => board_id}, []) do
      {:ok, %{"data" => %{"archive_board" => %{"id" => _}}}} ->
        :ok

      other ->
        Logger.warning("Failed to archive disposable Monday board #{board_id}: #{inspect(other)}")
        :ok
    end
  end

  defp wait_until_status_is(item_id, column_id, expected_text, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_status_is(item_id, column_id, expected_text, deadline)
  end

  defp do_wait_until_status_is(item_id, column_id, expected_text, deadline) do
    case fetch_item_snapshot(item_id, [column_id]) do
      {:ok, item} ->
        if status_text(item, column_id) == expected_text do
          true
        else
          maybe_retry(fn ->
            do_wait_until_status_is(item_id, column_id, expected_text, deadline)
          end, deadline)
        end

      {:error, _reason} ->
        maybe_retry(fn ->
          do_wait_until_status_is(item_id, column_id, expected_text, deadline)
        end, deadline)
    end
  end

  defp wait_until_workpad_present(item_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_workpad_present(item_id, deadline)
  end

  defp do_wait_until_workpad_present(item_id, deadline) do
    case fetch_item_snapshot(item_id, []) do
      {:ok, item} ->
        if has_workpad_update?(item) do
          true
        else
          maybe_retry(fn -> do_wait_until_workpad_present(item_id, deadline) end, deadline)
        end

      {:error, _reason} ->
        maybe_retry(fn -> do_wait_until_workpad_present(item_id, deadline) end, deadline)
    end
  end

  defp maybe_retry(fun, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(2_000)
      fun.()
    else
      false
    end
  end

  defp fetch_item_snapshot(item_id, column_ids) do
    vars = %{"itemId" => item_id, "columnIds" => column_ids}

    case Client.graphql(@item_status_query, vars, []) do
      {:ok, %{"data" => %{"items" => [item]}}} -> {:ok, item}
      {:ok, payload} -> {:error, {:unexpected_payload, payload}}
      {:error, _} = err -> err
    end
  end

  defp status_text(item, column_id) when is_map(item) and is_binary(column_id) do
    item
    |> Map.get("column_values", [])
    |> Enum.find_value(fn col ->
      if col["id"] == column_id, do: Map.get(col, "text"), else: nil
    end)
  end

  defp has_workpad_update?(item) when is_map(item) do
    item
    |> Map.get("updates", [])
    |> Enum.any?(fn update ->
      String.starts_with?(update["body"] || "", "## Symphony Workpad")
    end)
  end

  defp graphql_data!(query, variables) do
    case Client.graphql(query, variables, []) do
      {:ok, %{"data" => data, "errors" => errors}} when is_map(data) and is_list(errors) and errors != [] ->
        flunk("Monday GraphQL returned partial errors: #{inspect(errors)}")

      {:ok, %{"errors" => errors}} when is_list(errors) and errors != [] ->
        flunk("Monday GraphQL failed: #{inspect(errors)}")

      {:ok, %{"data" => data}} when is_map(data) ->
        data

      {:ok, payload} ->
        flunk("Monday GraphQL returned unexpected payload: #{inspect(payload)}")

      {:error, reason} ->
        flunk("Monday GraphQL request failed: #{inspect(reason)}")
    end
  end

  # --- WORKFLOW.md writer (Monday config; minimal & inline per task scope) ---

  defp write_monday_workflow_file!(path, opts) do
    board_id = Keyword.fetch!(opts, :board_id)
    symphony_status_column_id = Keyword.fetch!(opts, :symphony_status_column_id)
    pr_column_id = Keyword.fetch!(opts, :pr_column_id)
    heartbeat_item_id = Keyword.fetch!(opts, :heartbeat_item_id)
    workspace_root = Keyword.fetch!(opts, :workspace_root)
    worker_ssh_hosts = Keyword.get(opts, :worker_ssh_hosts, [])
    codex_command = Keyword.get(opts, :codex_command, "codex app-server")

    yaml = """
    ---
    tracker:
      kind: "monday"
      endpoint: "https://api.monday.com/v2"
      api_token: "$MONDAY_API_TOKEN"
      board_id: #{board_id}
      identifier_prefix: "SYM"
      symphony_status_column_id: "#{symphony_status_column_id}"
      pr_column_id: "#{pr_column_id}"
      heartbeat_item_id: #{heartbeat_item_id}
      heartbeat_ttl_ms: 60000
      complexity_budget_per_tick: 500
      backoff_factor: 2.0
      max_polling_interval_ms: 60000
      failure_ttl_count: 5
      active_states: #{yaml_string_list(@active_states)}
      handoff_states: #{yaml_string_list(@handoff_states)}
      terminal_states: #{yaml_string_list(@terminal_states)}
    polling:
      interval_ms: 5000
    workspace:
      root: "#{workspace_root}"
    #{worker_yaml(worker_ssh_hosts)}
    agent:
      max_concurrent_agents: 2
      max_turns: 3
      max_retry_backoff_ms: 30000
      max_concurrent_agents_by_state: {}
    codex:
      command: "#{codex_command}"
      approval_policy: "never"
      thread_sandbox: "workspace-write"
      turn_sandbox_policy: null
      turn_timeout_ms: 600000
      read_timeout_ms: 5000
      stall_timeout_ms: 600000
    hooks:
      timeout_ms: 60000
    observability:
      dashboard_enabled: false
      refresh_ms: 1000
      render_interval_ms: 16
    ---
    You are running a real Symphony end-to-end test against Monday.com.

    The orchestrator has dispatched you because the item's Symphony Status was set to
    "Symphony Ready". Your job for this test is just to record progress; the test
    harness verifies that Symphony's tracker writes (status -> "In Progress" and
    a Workpad Update on the item) occurred.

    Stop after writing a one-line summary; do not loop.
    """

    File.write!(path, yaml)
    :ok
  end

  defp yaml_string_list(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", fn v -> "\"" <> v <> "\"" end) <> "]"
  end

  defp worker_yaml([]), do: "worker:\n  ssh_hosts: []"

  defp worker_yaml(hosts) when is_list(hosts) do
    "worker:\n  ssh_hosts: " <> yaml_string_list(hosts)
  end

  # The Monday `defaults` field on a Status column is a JSON-encoded string of
  # label-id -> %{name, color} pairs. We assign deterministic colors that map
  # naturally to Symphony's lifecycle (ready=blue, in progress=yellow, done=green,
  # etc.) — Monday will accept any valid color string.
  defp status_defaults_json(labels) when is_list(labels) do
    palette = ~w(blue grass orange red purple green saladish lipstick navy bright-green dark-purple)

    labels_map =
      labels
      |> Enum.with_index()
      |> Enum.into(%{}, fn {name, idx} ->
        color = Enum.at(palette, rem(idx, length(palette)))
        {Integer.to_string(idx), %{"name" => name, "color" => color}}
      end)

    Jason.encode!(%{"labels" => labels_map})
  end

  # --- worker setup (preserved from prior Linear test; backends are tracker-agnostic) ---

  defp live_worker_setup!(:local, _run_id, test_root) when is_binary(test_root) do
    %{
      cleanup: fn -> :ok end,
      codex_command: "codex app-server",
      ssh_worker_hosts: [],
      workspace_root: Path.join(test_root, "workspaces")
    }
  end

  defp live_worker_setup!(:ssh, run_id, test_root) when is_binary(run_id) and is_binary(test_root) do
    case live_ssh_worker_hosts() do
      [] ->
        live_docker_worker_setup!(run_id, test_root)

      _hosts ->
        live_ssh_worker_setup!(run_id)
    end
  end

  defp cleanup_live_worker_setup(%{cleanup: cleanup}) when is_function(cleanup, 0) do
    cleanup.()
  end

  defp cleanup_live_worker_setup(_worker_setup), do: :ok

  defp restart_orchestrator_if_needed do
    if is_nil(Process.whereis(SymphonyElixir.Orchestrator)) do
      case Supervisor.restart_child(SymphonyElixir.Supervisor, SymphonyElixir.Orchestrator) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
        _other -> :ok
      end
    end
  end

  defp reload_workflow_store do
    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp live_ssh_worker_setup!(run_id) when is_binary(run_id) do
    ssh_worker_hosts = live_ssh_worker_hosts()
    remote_test_root = Path.join(shared_remote_home!(ssh_worker_hosts), ".#{run_id}")
    remote_workspace_root = "~/.#{run_id}/workspaces"

    %{
      cleanup: fn -> cleanup_remote_test_root(remote_test_root, ssh_worker_hosts) end,
      codex_command: "codex app-server",
      ssh_worker_hosts: ssh_worker_hosts,
      workspace_root: remote_workspace_root
    }
  end

  defp live_docker_worker_setup!(run_id, test_root) when is_binary(run_id) and is_binary(test_root) do
    ssh_root = Path.join(test_root, "live-docker-ssh")
    key_path = Path.join(ssh_root, "id_ed25519")
    config_path = Path.join(ssh_root, "config")
    auth_json_path = @default_docker_auth_json
    worker_ports = reserve_tcp_ports(@docker_worker_count)
    worker_hosts = Enum.map(worker_ports, &"localhost:#{&1}")
    project_name = docker_project_name(run_id)
    previous_ssh_config = System.get_env("SYMPHONY_SSH_CONFIG")

    base_cleanup = fn ->
      restore_env("SYMPHONY_SSH_CONFIG", previous_ssh_config)
      docker_compose_down(project_name, docker_compose_env(worker_ports, auth_json_path, key_path <> ".pub"))
    end

    result =
      try do
        File.mkdir_p!(ssh_root)
        generate_ssh_keypair!(key_path)
        write_docker_ssh_config!(config_path, key_path)
        System.put_env("SYMPHONY_SSH_CONFIG", config_path)

        docker_compose_up!(project_name, docker_compose_env(worker_ports, auth_json_path, key_path <> ".pub"))
        wait_for_ssh_hosts!(worker_hosts)
        remote_test_root = Path.join(shared_remote_home!(worker_hosts), ".#{run_id}")
        remote_workspace_root = "~/.#{run_id}/workspaces"

        %{
          cleanup: fn ->
            cleanup_remote_test_root(remote_test_root, worker_hosts)
            base_cleanup.()
          end,
          codex_command: "codex app-server",
          ssh_worker_hosts: worker_hosts,
          workspace_root: remote_workspace_root
        }
      rescue
        error ->
          {:error, error, __STACKTRACE__}
      catch
        kind, reason ->
          {:caught, kind, reason, __STACKTRACE__}
      end

    case result do
      %{ssh_worker_hosts: _hosts} = worker_setup ->
        worker_setup

      {:error, error, stacktrace} ->
        base_cleanup.()
        reraise(error, stacktrace)

      {:caught, kind, reason, stacktrace} ->
        base_cleanup.()
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp live_ssh_worker_hosts do
    System.get_env("SYMPHONY_LIVE_SSH_WORKER_HOSTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp cleanup_remote_test_root(test_root, ssh_worker_hosts)
       when is_binary(test_root) and is_list(ssh_worker_hosts) do
    Enum.each(ssh_worker_hosts, fn worker_host ->
      _ = SSH.run(worker_host, "rm -rf #{shell_escape(test_root)}", stderr_to_stdout: true)
    end)
  end

  defp shared_remote_home!([first_host | rest] = worker_hosts) when is_binary(first_host) and rest != [] do
    homes =
      worker_hosts
      |> Enum.map(fn worker_host -> {worker_host, remote_home!(worker_host)} end)

    [{_host, home} | _remaining] = homes

    if Enum.all?(homes, fn {_host, other_home} -> other_home == home end) do
      home
    else
      flunk("expected all live SSH workers to share one home directory, got: #{inspect(homes)}")
    end
  end

  defp shared_remote_home!([worker_host]) when is_binary(worker_host), do: remote_home!(worker_host)
  defp shared_remote_home!(_worker_hosts), do: flunk("expected at least one live SSH worker host")

  defp remote_home!(worker_host) when is_binary(worker_host) do
    case SSH.run(worker_host, "printf '%s\\n' \"$HOME\"", stderr_to_stdout: true) do
      {:ok, {output, 0}} ->
        output
        |> String.trim()
        |> case do
          "" -> flunk("expected non-empty remote home for #{worker_host}")
          home -> home
        end

      {:ok, {output, status}} ->
        flunk("failed to resolve remote home for #{worker_host} (status #{status}): #{inspect(output)}")

      {:error, reason} ->
        flunk("failed to resolve remote home for #{worker_host}: #{inspect(reason)}")
    end
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp reserve_tcp_ports(count) when is_integer(count) and count > 0 do
    reserve_tcp_ports(count, MapSet.new(), [])
  end

  defp reserve_tcp_ports(0, _seen, ports), do: Enum.reverse(ports)

  defp reserve_tcp_ports(remaining, seen, ports) do
    port = reserve_tcp_port!()

    if MapSet.member?(seen, port) do
      reserve_tcp_ports(remaining, seen, ports)
    else
      reserve_tcp_ports(remaining - 1, MapSet.put(seen, port), [port | ports])
    end
  end

  defp reserve_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, {:active, false}, {:reuseaddr, true}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp generate_ssh_keypair!(key_path) when is_binary(key_path) do
    case System.find_executable("ssh-keygen") do
      nil ->
        flunk("docker worker mode requires `ssh-keygen` on PATH")

      executable ->
        key_dir = Path.dirname(key_path)
        File.mkdir_p!(key_dir)
        File.rm_rf(key_path)
        File.rm_rf(key_path <> ".pub")

        case System.cmd(executable, ["-q", "-t", "ed25519", "-N", "", "-f", key_path], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("failed to generate live docker ssh key (status #{status}): #{inspect(output)}")
        end
    end
  end

  defp write_docker_ssh_config!(config_path, key_path)
       when is_binary(config_path) and is_binary(key_path) do
    config_contents = """
    Host localhost 127.0.0.1
      User root
      IdentityFile #{key_path}
      IdentitiesOnly yes
      StrictHostKeyChecking no
      UserKnownHostsFile /dev/null
      LogLevel ERROR
    """

    File.mkdir_p!(Path.dirname(config_path))
    File.write!(config_path, config_contents)
  end

  defp docker_project_name(run_id) when is_binary(run_id) do
    run_id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "-")
  end

  defp docker_compose_env(worker_ports, auth_json_path, authorized_key_path)
       when is_list(worker_ports) and is_binary(auth_json_path) and is_binary(authorized_key_path) do
    [
      {"SYMPHONY_LIVE_DOCKER_AUTH_JSON", auth_json_path},
      {"SYMPHONY_LIVE_DOCKER_AUTHORIZED_KEY", authorized_key_path},
      {"SYMPHONY_LIVE_DOCKER_WORKER_1_PORT", Integer.to_string(Enum.at(worker_ports, 0))},
      {"SYMPHONY_LIVE_DOCKER_WORKER_2_PORT", Integer.to_string(Enum.at(worker_ports, 1))}
    ]
  end

  defp docker_compose_up!(project_name, env) when is_binary(project_name) and is_list(env) do
    args = ["compose", "-f", @docker_compose_file, "-p", project_name, "up", "-d", "--build"]

    case System.cmd("docker", args, cd: @docker_support_dir, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        flunk("failed to start live docker workers (status #{status}): #{inspect(output)}")
    end
  end

  defp docker_compose_down(project_name, env) when is_binary(project_name) and is_list(env) do
    _ =
      System.cmd(
        "docker",
        ["compose", "-f", @docker_compose_file, "-p", project_name, "down", "-v", "--remove-orphans"],
        cd: @docker_support_dir,
        env: env,
        stderr_to_stdout: true
      )

    :ok
  end

  defp wait_for_ssh_hosts!(worker_hosts) when is_list(worker_hosts) do
    deadline = System.monotonic_time(:millisecond) + 60_000

    Enum.each(worker_hosts, fn worker_host ->
      wait_for_ssh_host!(worker_host, deadline)
    end)
  end

  defp wait_for_ssh_host!(worker_host, deadline_ms) when is_binary(worker_host) do
    case SSH.run(worker_host, "printf ready", stderr_to_stdout: true) do
      {:ok, {"ready", 0}} ->
        :ok

      {:ok, {_output, _status}} ->
        retry_or_flunk_ssh_host(worker_host, deadline_ms)

      {:error, _reason} ->
        retry_or_flunk_ssh_host(worker_host, deadline_ms)
    end
  end

  defp retry_or_flunk_ssh_host(worker_host, deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(1_000)
      wait_for_ssh_host!(worker_host, deadline_ms)
    else
      flunk("timed out waiting for SSH worker #{worker_host} to accept connections")
    end
  end
end
