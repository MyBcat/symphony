defmodule SymphonyElixir.TestSupport do
  @workflow_prompt "You are an agent for this repository."

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case
      import ExUnit.CaptureLog

      alias SymphonyElixir.AgentRunner
      alias SymphonyElixir.CLI
      alias SymphonyElixir.Codex.Adapter
      alias SymphonyElixir.Config
      alias SymphonyElixir.HttpServer
      alias SymphonyElixir.Orchestrator
      alias SymphonyElixir.PromptBuilder
      alias SymphonyElixir.StatusDashboard
      alias SymphonyElixir.Tracker
      alias SymphonyElixir.Tracker.Issue
      alias SymphonyElixir.Workflow
      alias SymphonyElixir.WorkflowStore
      alias SymphonyElixir.Workspace

      import SymphonyElixir.TestSupport,
        only: [
          write_workflow_file!: 1,
          write_workflow_file!: 2,
          restore_env: 2,
          stop_default_http_server: 0
        ]

      setup do
        workflow_root =
          Path.join(
            System.tmp_dir!(),
            "symphony-elixir-workflow-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(workflow_root)
        workflow_file = Path.join(workflow_root, "WORKFLOW.md")
        write_workflow_file!(workflow_file)
        Workflow.set_workflow_file_path(workflow_file)

        # Redirect Codex.ProjectTrust writes to a per-test temp file so the
        # adapter's auto-trust step never touches the developer's real
        # ~/.codex/config.toml. Tests that need to inspect the trust file
        # can read the configured path back via ProjectTrust.config_path/0.
        codex_trust_path = Path.join(workflow_root, "codex_config.toml")
        previous_codex_trust_path = System.get_env("SYMPHONY_CODEX_CONFIG_TOML")
        System.put_env("SYMPHONY_CODEX_CONFIG_TOML", codex_trust_path)

        if Process.whereis(SymphonyElixir.WorkflowStore),
          do: SymphonyElixir.WorkflowStore.force_reload()

        stop_default_http_server()

        on_exit(fn ->
          Application.delete_env(:symphony_elixir, :workflow_file_path)
          Application.delete_env(:symphony_elixir, :server_port_override)
          Application.delete_env(:symphony_elixir, :memory_tracker_issues)
          Application.delete_env(:symphony_elixir, :memory_tracker_recipient)

          if is_binary(previous_codex_trust_path) do
            System.put_env("SYMPHONY_CODEX_CONFIG_TOML", previous_codex_trust_path)
          else
            System.delete_env("SYMPHONY_CODEX_CONFIG_TOML")
          end

          File.rm_rf(workflow_root)
        end)

        :ok
      end
    end
  end

  def write_workflow_file!(path, overrides \\ []) do
    workflow = workflow_content(overrides)
    File.write!(path, workflow)

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      try do
        SymphonyElixir.WorkflowStore.force_reload()
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  def restore_env(key, nil), do: System.delete_env(key)
  def restore_env(key, value), do: System.put_env(key, value)

  def stop_default_http_server do
    # When tests run with `--no-start`, the OTP supervisor isn't up; nothing to
    # stop. Guard the lookup so test setup remains identical across both modes.
    if Process.whereis(SymphonyElixir.Supervisor) do
      case Enum.find(Supervisor.which_children(SymphonyElixir.Supervisor), fn
             {SymphonyElixir.HttpServer, _pid, _type, _modules} -> true
             _child -> false
           end) do
        {SymphonyElixir.HttpServer, pid, _type, _modules} when is_pid(pid) ->
          :ok = Supervisor.terminate_child(SymphonyElixir.Supervisor, SymphonyElixir.HttpServer)

          if Process.alive?(pid) do
            Process.exit(pid, :normal)
          end

          :ok

        _ ->
          :ok
      end
    else
      :ok
    end
  end

  defp workflow_content(overrides) do
    config =
      Keyword.merge(
        [
          tracker_kind: "monday",
          tracker_endpoint: "https://api.monday.com/v2",
          tracker_api_token: "token",
          tracker_board_id: 123_456_789,
          tracker_identifier_prefix: "SYM",
          tracker_status_column_id: "symphony_status",
          tracker_profile_column_id: "symphony_profile",
          tracker_repo_column_id: nil,
          tracker_pr_column_id: "pr_link",
          tracker_heartbeat_item_id: 987_654_321,
          tracker_active_states: ["Symphony Ready", "In Progress", "Rework"],
          tracker_handoff_states: ["Human Review", "Merging"],
          tracker_terminal_states: ["Done", "Cancelled"],
          poll_interval_ms: 30_000,
          workspace_root: Path.join(System.tmp_dir!(), "symphony_workspaces"),
          worker_ssh_hosts: [],
          worker_max_concurrent_agents_per_host: nil,
          max_concurrent_agents: 10,
          max_turns: 20,
          max_retry_backoff_ms: 300_000,
          max_concurrent_agents_by_state: %{},
          agent_default_profile: nil,
          agent_sandbox_safety_floor: nil,
          profiles: nil,
          repo_policy_allowed_clone_hosts: nil,
          repos: nil,
          codex_command: "codex app-server",
          codex_approval_policy: %{
            reject: %{sandbox_approval: true, rules: true, mcp_elicitations: true}
          },
          codex_thread_sandbox: "workspace-write",
          codex_turn_sandbox_policy: nil,
          codex_turn_timeout_ms: 3_600_000,
          codex_read_timeout_ms: 5_000,
          codex_stall_timeout_ms: 300_000,
          hook_after_create: nil,
          hook_before_run: nil,
          hook_after_run: nil,
          hook_before_remove: nil,
          hook_timeout_ms: 60_000,
          observability_enabled: true,
          observability_refresh_ms: 1_000,
          observability_render_interval_ms: 16,
          server_port: nil,
          server_host: nil,
          prompt: @workflow_prompt
        ],
        overrides
      )

    tracker_kind = Keyword.get(config, :tracker_kind)
    tracker_endpoint = Keyword.get(config, :tracker_endpoint)
    tracker_api_token = Keyword.get(config, :tracker_api_token)
    tracker_board_id = Keyword.get(config, :tracker_board_id)
    tracker_identifier_prefix = Keyword.get(config, :tracker_identifier_prefix)
    tracker_status_column_id = Keyword.get(config, :tracker_status_column_id)
    tracker_profile_column_id = Keyword.get(config, :tracker_profile_column_id)
    tracker_repo_column_id = Keyword.get(config, :tracker_repo_column_id)
    tracker_pr_column_id = Keyword.get(config, :tracker_pr_column_id)
    tracker_heartbeat_item_id = Keyword.get(config, :tracker_heartbeat_item_id)
    tracker_active_states = Keyword.get(config, :tracker_active_states)
    tracker_handoff_states = Keyword.get(config, :tracker_handoff_states)
    tracker_terminal_states = Keyword.get(config, :tracker_terminal_states)
    poll_interval_ms = Keyword.get(config, :poll_interval_ms)
    workspace_root = Keyword.get(config, :workspace_root)
    worker_ssh_hosts = Keyword.get(config, :worker_ssh_hosts)

    worker_max_concurrent_agents_per_host =
      Keyword.get(config, :worker_max_concurrent_agents_per_host)

    max_concurrent_agents = Keyword.get(config, :max_concurrent_agents)
    max_turns = Keyword.get(config, :max_turns)
    max_retry_backoff_ms = Keyword.get(config, :max_retry_backoff_ms)
    max_concurrent_agents_by_state = Keyword.get(config, :max_concurrent_agents_by_state)
    agent_default_profile = Keyword.get(config, :agent_default_profile)
    agent_sandbox_safety_floor = Keyword.get(config, :agent_sandbox_safety_floor)
    profiles = Keyword.get(config, :profiles)
    repo_policy_allowed_clone_hosts = Keyword.get(config, :repo_policy_allowed_clone_hosts)
    repos = Keyword.get(config, :repos)
    codex_command = Keyword.get(config, :codex_command)
    codex_approval_policy = Keyword.get(config, :codex_approval_policy)
    codex_thread_sandbox = Keyword.get(config, :codex_thread_sandbox)
    codex_turn_sandbox_policy = Keyword.get(config, :codex_turn_sandbox_policy)
    codex_turn_timeout_ms = Keyword.get(config, :codex_turn_timeout_ms)
    codex_read_timeout_ms = Keyword.get(config, :codex_read_timeout_ms)
    codex_stall_timeout_ms = Keyword.get(config, :codex_stall_timeout_ms)
    hook_after_create = Keyword.get(config, :hook_after_create)
    hook_before_run = Keyword.get(config, :hook_before_run)
    hook_after_run = Keyword.get(config, :hook_after_run)
    hook_before_remove = Keyword.get(config, :hook_before_remove)
    hook_timeout_ms = Keyword.get(config, :hook_timeout_ms)
    observability_enabled = Keyword.get(config, :observability_enabled)
    observability_refresh_ms = Keyword.get(config, :observability_refresh_ms)
    observability_render_interval_ms = Keyword.get(config, :observability_render_interval_ms)
    server_port = Keyword.get(config, :server_port)
    server_host = Keyword.get(config, :server_host)
    prompt = Keyword.get(config, :prompt)

    sections =
      [
        "---",
        "tracker:",
        "  kind: #{yaml_value(tracker_kind)}",
        "  endpoint: #{yaml_value(tracker_endpoint)}",
        "  api_token: #{yaml_value(tracker_api_token)}",
        "  board_id: #{yaml_value(tracker_board_id)}",
        "  identifier_prefix: #{yaml_value(tracker_identifier_prefix)}",
        "  symphony_status_column_id: #{yaml_value(tracker_status_column_id)}",
        "  profile_column_id: #{yaml_value(tracker_profile_column_id)}",
        tracker_optional_field("repo_column_id", tracker_repo_column_id),
        "  pr_column_id: #{yaml_value(tracker_pr_column_id)}",
        "  heartbeat_item_id: #{yaml_value(tracker_heartbeat_item_id)}",
        "  active_states: #{yaml_value(tracker_active_states)}",
        "  handoff_states: #{yaml_value(tracker_handoff_states)}",
        "  terminal_states: #{yaml_value(tracker_terminal_states)}",
        "polling:",
        "  interval_ms: #{yaml_value(poll_interval_ms)}",
        "workspace:",
        "  root: #{yaml_value(workspace_root)}",
        worker_yaml(worker_ssh_hosts, worker_max_concurrent_agents_per_host),
        "agent:",
        "  max_concurrent_agents: #{yaml_value(max_concurrent_agents)}",
        "  max_turns: #{yaml_value(max_turns)}",
        "  max_retry_backoff_ms: #{yaml_value(max_retry_backoff_ms)}",
        "  max_concurrent_agents_by_state: #{yaml_value(max_concurrent_agents_by_state)}",
        agent_optional_field("default_profile", agent_default_profile),
        agent_optional_field("sandbox_safety_floor", agent_sandbox_safety_floor),
        profiles_yaml(profiles),
        repo_policy_yaml(repo_policy_allowed_clone_hosts),
        repos_yaml(repos),
        "codex:",
        "  command: #{yaml_value(codex_command)}",
        "  approval_policy: #{yaml_value(codex_approval_policy)}",
        "  thread_sandbox: #{yaml_value(codex_thread_sandbox)}",
        "  turn_sandbox_policy: #{yaml_value(codex_turn_sandbox_policy)}",
        "  turn_timeout_ms: #{yaml_value(codex_turn_timeout_ms)}",
        "  read_timeout_ms: #{yaml_value(codex_read_timeout_ms)}",
        "  stall_timeout_ms: #{yaml_value(codex_stall_timeout_ms)}",
        hooks_yaml(
          hook_after_create,
          hook_before_run,
          hook_after_run,
          hook_before_remove,
          hook_timeout_ms
        ),
        observability_yaml(
          observability_enabled,
          observability_refresh_ms,
          observability_render_interval_ms
        ),
        server_yaml(server_port, server_host),
        "---",
        prompt
      ]
      |> Enum.reject(&(&1 in [nil, ""]))

    Enum.join(sections, "\n") <> "\n"
  end

  defp yaml_value(value) when is_binary(value) do
    "\"" <> String.replace(value, "\"", "\\\"") <> "\""
  end

  defp yaml_value(value) when is_integer(value), do: to_string(value)
  defp yaml_value(true), do: "true"
  defp yaml_value(false), do: "false"
  defp yaml_value(nil), do: "null"

  defp yaml_value(values) when is_list(values) do
    "[" <> Enum.map_join(values, ", ", &yaml_value/1) <> "]"
  end

  defp yaml_value(values) when is_map(values) do
    "{" <>
      Enum.map_join(values, ", ", fn {key, value} ->
        "#{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end) <> "}"
  end

  defp yaml_value(value), do: yaml_value(to_string(value))

  defp hooks_yaml(nil, nil, nil, nil, timeout_ms),
    do: "hooks:\n  timeout_ms: #{yaml_value(timeout_ms)}"

  defp hooks_yaml(
         hook_after_create,
         hook_before_run,
         hook_after_run,
         hook_before_remove,
         timeout_ms
       ) do
    [
      "hooks:",
      "  timeout_ms: #{yaml_value(timeout_ms)}",
      hook_entry("after_create", hook_after_create),
      hook_entry("before_run", hook_before_run),
      hook_entry("after_run", hook_after_run),
      hook_entry("before_remove", hook_before_remove)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host)
       when ssh_hosts in [nil, []] and is_nil(max_concurrent_agents_per_host),
       do: nil

  defp worker_yaml(ssh_hosts, max_concurrent_agents_per_host) do
    [
      "worker:",
      ssh_hosts not in [nil, []] && "  ssh_hosts: #{yaml_value(ssh_hosts)}",
      !is_nil(max_concurrent_agents_per_host) &&
        "  max_concurrent_agents_per_host: #{yaml_value(max_concurrent_agents_per_host)}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp observability_yaml(enabled, refresh_ms, render_interval_ms) do
    [
      "observability:",
      "  dashboard_enabled: #{yaml_value(enabled)}",
      "  refresh_ms: #{yaml_value(refresh_ms)}",
      "  render_interval_ms: #{yaml_value(render_interval_ms)}"
    ]
    |> Enum.join("\n")
  end

  defp server_yaml(nil, nil), do: nil

  defp server_yaml(port, host) do
    [
      "server:",
      port && "  port: #{yaml_value(port)}",
      host && "  host: #{yaml_value(host)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp hook_entry(_name, nil), do: nil

  defp hook_entry(name, command) when is_binary(command) do
    indented =
      command
      |> String.split("\n")
      |> Enum.map_join("\n", &("    " <> &1))

    "  #{name}: |\n#{indented}"
  end

  defp agent_optional_field(_name, nil), do: nil
  defp agent_optional_field(name, value), do: "  #{name}: #{yaml_value(value)}"

  defp tracker_optional_field(_name, nil), do: nil
  defp tracker_optional_field(name, value), do: "  #{name}: #{yaml_value(value)}"

  defp profiles_yaml(nil), do: nil

  defp profiles_yaml(profiles) when is_map(profiles) and map_size(profiles) == 0, do: nil

  defp profiles_yaml(profiles) when is_map(profiles) do
    body =
      profiles
      |> Enum.map_join("\n", fn {name, profile_map} ->
        profile_yaml_entry(to_string(name), profile_map)
      end)

    "profiles:\n" <> body
  end

  defp profile_yaml_entry(name, profile_map) when is_map(profile_map) do
    kind = Map.get(profile_map, :kind) || Map.get(profile_map, "kind")

    max_concurrent =
      Map.get(profile_map, :max_concurrent) || Map.get(profile_map, "max_concurrent")

    nested_config = Map.get(profile_map, kind_atom(kind)) || Map.get(profile_map, to_string(kind))

    base = [
      "  #{yaml_value(name)}:",
      "    kind: #{yaml_value(to_string(kind))}"
    ]

    base
    |> append_max_concurrent(max_concurrent)
    |> append_nested_config(kind, nested_config)
    |> Enum.join("\n")
  end

  defp kind_atom(nil), do: nil
  defp kind_atom(kind) when is_binary(kind), do: String.to_atom(kind)
  defp kind_atom(kind) when is_atom(kind), do: kind

  defp append_max_concurrent(lines, nil), do: lines

  defp append_max_concurrent(lines, max_concurrent) do
    lines ++ ["    max_concurrent: #{yaml_value(max_concurrent)}"]
  end

  defp append_nested_config(lines, _kind, nil), do: lines
  defp append_nested_config(lines, _kind, config) when map_size(config) == 0, do: lines

  defp append_nested_config(lines, kind, config) when is_map(config) do
    nested_lines =
      Enum.map(config, fn {key, value} ->
        "      #{yaml_value(to_string(key))}: #{yaml_value(value)}"
      end)

    lines ++ ["    #{yaml_value(to_string(kind))}:" | nested_lines]
  end

  defp repo_policy_yaml(nil), do: nil

  defp repo_policy_yaml(allowed_clone_hosts) do
    "repo_policy:\n  allowed_clone_hosts: #{yaml_value(allowed_clone_hosts)}"
  end

  defp repos_yaml(nil), do: nil
  defp repos_yaml(repos) when is_map(repos) and map_size(repos) == 0, do: nil

  defp repos_yaml(repos) when is_map(repos) do
    body =
      repos
      |> Enum.map_join("\n", fn {key, repo_map} ->
        repo_yaml_entry(to_string(key), repo_map)
      end)

    "repos:\n" <> body
  end

  defp repo_yaml_entry(name, repo_map) when is_map(repo_map) do
    fields =
      [
        repo_yaml_field("clone_url", Map.get(repo_map, :clone_url) || Map.get(repo_map, "clone_url")),
        repo_yaml_field("after_create", Map.get(repo_map, :after_create) || Map.get(repo_map, "after_create")),
        repo_yaml_field("before_remove", Map.get(repo_map, :before_remove) || Map.get(repo_map, "before_remove")),
        repo_yaml_field(
          "allowed_profiles",
          Map.get(repo_map, :allowed_profiles) || Map.get(repo_map, "allowed_profiles")
        ),
        repo_yaml_field(
          "default_branch",
          Map.get(repo_map, :default_branch) || Map.get(repo_map, "default_branch")
        )
      ]
      |> Enum.reject(&is_nil/1)

    ["  #{yaml_value(name)}:" | fields]
    |> Enum.join("\n")
  end

  defp repo_yaml_field(_name, nil), do: nil
  defp repo_yaml_field(name, value), do: "    #{name}: #{yaml_value(value)}"
end
