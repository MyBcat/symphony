defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  require Logger

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Monday.com item.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t(),
          turn_sandbox_policy: map()
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec repos() :: map()
  def repos do
    settings!().repos || %{}
  end

  @doc """
  Returns the configured `secret_exec.py` path. Falls back to the resolver's
  default when WORKFLOW.md does not set `secrets.secret_exec_path`.
  """
  @spec secret_exec_path() :: String.t()
  def secret_exec_path do
    case settings!().secrets do
      %{secret_exec_path: path} when is_binary(path) and path != "" ->
        path

      _ ->
        SymphonyElixir.Secrets.Resolver.default_secret_exec_path()
    end
  end

  @doc """
  Returns the per-repo secrets list as a `%{repo_key => [ref, ...]}` map.
  Empty/missing lists are omitted so callers can treat the result as the
  authoritative dispatch-time list.
  """
  @spec secrets_by_repo() :: %{String.t() => [String.t()]}
  def secrets_by_repo do
    settings!()
    |> Map.get(:repos)
    |> Kernel.||(%{})
    |> Enum.flat_map(fn
      {key, %{secrets: secrets}} when is_list(secrets) and secrets != [] ->
        [{key, secrets}]

      _ ->
        []
    end)
    |> Enum.into(%{})
  end

  @spec repo_policy() :: Schema.RepoPolicy.t()
  def repo_policy do
    settings!().repo_policy
  end

  @spec repo!(String.t()) :: Schema.RepoEntry.t()
  def repo!(repo_key) when is_binary(repo_key) do
    key = String.trim(repo_key)

    case Map.fetch(repos(), key) do
      {:ok, repo} ->
        repo

      :error ->
        raise KeyError, key: key, term: repos()
    end
  end

  @spec repo_or_default(String.t() | nil) ::
          {:ok, {:repo, String.t(), Schema.RepoEntry.t()}}
          | {:ok, {:default, map()}}
          | {:error, {:unknown_repo, String.t()}}
          | {:error, :no_default_repo}
  def repo_or_default(repo_key) do
    settings = settings!()

    if blank?(settings.tracker.repo_column_id) do
      default_repo(settings, false)
    else
      case normalize_repo_key(repo_key) do
        nil ->
          default_repo(settings, true)

        key ->
          case Map.fetch(settings.repos || %{}, key) do
            {:ok, repo} -> {:ok, {:repo, key, repo}}
            :error -> {:error, {:unknown_repo, key}}
          end
      end
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 ->
        port

      _ ->
        settings = settings!()
        dashboard = settings.dashboard

        cond do
          dashboard != nil and is_integer(dashboard.port) and dashboard.enabled != false ->
            dashboard.port

          true ->
            settings.server.port
        end
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: settings.codex.thread_sandbox,
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  @doc false
  @spec validate_semantics(Schema.t()) :: :ok | {:error, term()}
  def validate_semantics(settings) do
    cond do
      is_nil(settings.tracker.kind) ->
        {:error, :missing_tracker_kind}

      settings.tracker.kind not in ["monday", "memory"] ->
        {:error, {:unsupported_tracker_kind, settings.tracker.kind}}

      settings.tracker.kind == "monday" and not is_binary(settings.tracker.api_token) ->
        {:error, :missing_monday_api_token}

      settings.tracker.kind == "monday" and not is_integer(settings.tracker.board_id) ->
        {:error, :missing_monday_board_id}

      settings.tracker.kind == "monday" and
          not is_binary(settings.tracker.symphony_status_column_id) ->
        {:error, :missing_monday_status_column}

      settings.tracker.kind == "monday" and not is_integer(settings.tracker.heartbeat_item_id) ->
        {:error, :missing_monday_heartbeat_item_id}

      settings.tracker.kind == "monday" and blank?(settings.tracker.profile_column_id) ->
        {:error, :missing_monday_profile_column}

      handoff_active_overlap(settings.tracker) != [] ->
        {:error, {:handoff_states_overlap_active_states, handoff_active_overlap(settings.tracker)}}

      settings.agent.default_profile not in [nil, ""] and
          not Map.has_key?(settings.profiles, settings.agent.default_profile) ->
        {:error, {:default_profile_not_in_profiles_map, settings.agent.default_profile}}

      unknown_kind_profile(settings.profiles) != nil ->
        {:error, {:unknown_profile_kind, unknown_kind_profile(settings.profiles)}}

      invalid_profile_max_concurrent(settings.profiles) != nil ->
        {:error, {:invalid_profile_max_concurrent, invalid_profile_max_concurrent(settings.profiles)}}

      profile_safety_floor_violation(settings) != nil ->
        {:error, {:profile_safety_floor_violation, profile_safety_floor_violation(settings)}}

      repo_semantics_error(settings) != nil ->
        {:error, repo_semantics_error(settings)}

      true ->
        warn_repo_legacy_mode(settings)
        :ok
    end
  end

  @clone_shell_metacharacters ~r/[;&|`$<>\n\r\0]/
  @url_encoded_path_separators ~w(%2f %5c)
  @repo_legacy_mode_warning_key {__MODULE__, :repo_legacy_mode_warning_emitted}

  defp default_repo(settings, require_hook?) do
    after_create = settings.hooks.after_create

    if require_hook? and blank?(after_create) do
      {:error, :no_default_repo}
    else
      {:ok, {:default, %{repo_key: "<default>", after_create: after_create}}}
    end
  end

  defp normalize_repo_key(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_repo_key(_value), do: nil

  defp repo_semantics_error(settings) do
    with :ok <- validate_allowed_clone_hosts(settings.repo_policy.allowed_clone_hosts || []),
         :ok <- validate_repos(settings.repos || %{}, settings) do
      nil
    else
      {:error, reason} -> reason
    end
  end

  defp validate_allowed_clone_hosts(hosts) when is_list(hosts) and hosts != [] do
    Enum.reduce_while(hosts, :ok, fn host, :ok ->
      host = to_string(host)

      cond do
        not ascii?(host) ->
          {:halt, {:error, {:invalid_repo_allowed_clone_host, host, :non_ascii}}}

        host != String.downcase(host) or blank?(host) or String.contains?(host, ["*", "/"]) ->
          {:halt, {:error, {:invalid_repo_allowed_clone_host, host, :invalid_host}}}

        punycode_host?(host) ->
          {:halt, {:error, {:invalid_repo_allowed_clone_host, host, :punycode_host}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_allowed_clone_hosts(_hosts),
    do: {:error, {:invalid_repo_allowed_clone_hosts, :empty}}

  defp validate_repos(repos, settings) when is_map(repos) do
    repos
    |> Enum.sort_by(fn {key, _repo} -> key end)
    |> Enum.reduce_while(:ok, fn {key, repo}, :ok ->
      case validate_repo_entry(key, repo, settings) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_repo_entry(key, repo, settings) do
    cond do
      blank?(repo.clone_url) ->
        {:error, {:missing_repo_clone_url, key}}

      true ->
        with :ok <- validate_clone_url(key, repo.clone_url, settings.repo_policy.allowed_clone_hosts),
             :ok <- validate_repo_hook(key, repo.after_create),
             :ok <- validate_allowed_profiles(key, repo.allowed_profiles, settings.profiles) do
          validate_repo_secrets(key, repo.secrets)
        end
    end
  end

  defp validate_repo_secrets(_key, nil), do: :ok
  defp validate_repo_secrets(_key, []), do: :ok

  defp validate_repo_secrets(key, secrets) when is_list(secrets) do
    case SymphonyElixir.Secrets.Resolver.parse_refs(secrets) do
      {:ok, _specs} -> :ok
      {:error, reason} -> {:error, {:invalid_repo_secrets, key, reason}}
    end
  end

  defp validate_repo_secrets(key, _other), do: {:error, {:invalid_repo_secrets, key, :not_a_list}}

  defp validate_clone_url(key, clone_url, allowed_hosts) when is_binary(clone_url) do
    cond do
      clone_url != String.normalize(clone_url, :nfc) ->
        {:error, {:unsafe_clone_url, key, :not_nfc}}

      not ascii?(clone_url) ->
        {:error, {:unsafe_clone_url, key, :non_ascii}}

      control_characters?(clone_url) ->
        {:error, {:unsafe_clone_url, key, :control_characters}}

      env_indirection?(clone_url) ->
        {:error, {:unsafe_clone_url, key, :env_indirection}}

      String.match?(clone_url, @clone_shell_metacharacters) ->
        {:error, {:unsafe_clone_url, key, :shell_metacharacters}}

      String.contains?(clone_url, "\\") ->
        {:error, {:unsafe_clone_url, key, :backslash}}

      encoded_path_separator?(clone_url) ->
        {:error, {:unsafe_clone_url, key, :encoded_path_separator}}

      true ->
        parse_clone_url(key, clone_url, allowed_hosts)
    end
  end

  defp validate_clone_url(key, _clone_url, _allowed_hosts),
    do: {:error, {:unsafe_clone_url, key, :invalid_format}}

  defp parse_clone_url(key, "git@" <> _ = clone_url, allowed_hosts) do
    case Regex.run(~r/\Agit@([^:\/\\]+):([^\/\\]+)\/([^\/\\]+)\z/, clone_url) do
      [_url, host, org, repo] ->
        with :ok <- validate_clone_host(key, host, allowed_hosts) do
          validate_clone_path_segments(key, [org, repo])
        end

      _ ->
        {:error, {:unsafe_clone_url, key, :invalid_format}}
    end
  end

  defp parse_clone_url(key, "https://" <> _ = clone_url, allowed_hosts) do
    uri = URI.parse(clone_url)

    cond do
      uri.scheme != "https" or is_nil(uri.host) ->
        {:error, {:unsafe_clone_url, key, :invalid_format}}

      not is_nil(uri.userinfo) ->
        {:error, {:unsafe_clone_url, key, :embedded_credentials}}

      not is_nil(uri.query) or not is_nil(uri.fragment) ->
        {:error, {:unsafe_clone_url, key, :invalid_format}}

      true ->
        with :ok <- validate_clone_host(key, uri.host, allowed_hosts),
             {:ok, segments} <- https_path_segments(key, uri.path) do
          validate_clone_path_segments(key, segments)
        end
    end
  end

  defp parse_clone_url(key, _clone_url, _allowed_hosts),
    do: {:error, {:unsafe_clone_url, key, :invalid_format}}

  defp validate_clone_host(key, host, allowed_hosts) do
    host = to_string(host)
    allowed_hosts = MapSet.new(Enum.map(allowed_hosts, &to_string/1))

    cond do
      blank?(host) ->
        {:error, {:unsafe_clone_url, key, :invalid_host}}

      host != String.downcase(host) ->
        {:error, {:unsafe_clone_url, key, {:host_not_allowed, host}}}

      not ascii?(host) ->
        {:error, {:unsafe_clone_url, key, :non_ascii}}

      invalid_host_labels?(host) ->
        {:error, {:unsafe_clone_url, key, :invalid_host}}

      punycode_host?(host) ->
        {:error, {:unsafe_clone_url, key, :punycode_host}}

      not MapSet.member?(allowed_hosts, host) ->
        {:error, {:unsafe_clone_url, key, {:host_not_allowed, host}}}

      true ->
        :ok
    end
  end

  defp https_path_segments(key, path) when is_binary(path) do
    case String.split(path, "/", trim: false) do
      ["", org, repo] -> {:ok, [org, repo]}
      _ -> {:error, {:unsafe_clone_url, key, :invalid_path}}
    end
  end

  defp https_path_segments(key, _path), do: {:error, {:unsafe_clone_url, key, :invalid_path}}

  defp validate_clone_path_segments(key, [_org, repo] = segments) do
    cond do
      Enum.any?(segments, &invalid_path_segment?/1) ->
        {:error, {:unsafe_clone_url, key, :invalid_path}}

      not String.ends_with?(repo, ".git") ->
        {:error, {:unsafe_clone_url, key, :invalid_path}}

      true ->
        :ok
    end
  end

  defp validate_repo_hook(_key, nil), do: :ok

  defp validate_repo_hook(key, command) when is_binary(command) do
    normalized = String.downcase(command)

    cond do
      Regex.match?(~r/\bgit\s+clone\b/, normalized) ->
        {:error, {:unsafe_repo_hook, key, :git_clone}}

      Regex.match?(~r/\bgit\s+submodule\b/, normalized) ->
        {:error, {:unsafe_repo_hook, key, :git_submodule}}

      true ->
        :ok
    end
  end

  defp validate_repo_hook(key, _command), do: {:error, {:unsafe_repo_hook, key, :invalid_hook}}

  defp validate_allowed_profiles(_key, nil, _profiles), do: :ok
  defp validate_allowed_profiles(_key, [], _profiles), do: :ok

  defp validate_allowed_profiles(key, allowed_profiles, profiles) when is_list(allowed_profiles) do
    profile_names = MapSet.new(Map.keys(profiles || %{}))

    Enum.reduce_while(allowed_profiles, :ok, fn profile, :ok ->
      profile = to_string(profile)

      if MapSet.member?(profile_names, profile) do
        {:cont, :ok}
      else
        {:halt, {:error, {:repo_allowed_profile_not_found, key, profile}}}
      end
    end)
  end

  defp validate_allowed_profiles(key, _allowed_profiles, _profiles),
    do: {:error, {:invalid_repo_allowed_profiles, key}}

  defp warn_repo_legacy_mode(settings) do
    repos = settings.repos || %{}

    if blank?(settings.tracker.repo_column_id) and map_size(repos) > 0 do
      unless Process.get(@repo_legacy_mode_warning_key) do
        Process.put(@repo_legacy_mode_warning_key, true)

        Logger.warning("repo_column_id unset; multi-repo dispatch disabled; repos map is ignored until tracker.repo_column_id is set")
      end
    end
  end

  defp ascii?(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 in 0..127))
  end

  defp control_characters?(value) when is_binary(value) do
    value
    |> :binary.bin_to_list()
    |> Enum.any?(&(&1 in 0..31 or &1 == 127))
  end

  defp env_indirection?(value) when is_binary(value) do
    String.starts_with?(value, "$") or String.contains?(value, ["${", "{{"])
  end

  defp encoded_path_separator?(value) when is_binary(value) do
    lower = String.downcase(value)
    Enum.any?(@url_encoded_path_separators, &String.contains?(lower, &1))
  end

  defp invalid_host_labels?(host) do
    labels = String.split(host, ".", trim: false)
    labels == [] or Enum.any?(labels, &(&1 == ""))
  end

  defp punycode_host?(host) do
    host
    |> String.split(".")
    |> Enum.any?(&String.starts_with?(&1, "xn--"))
  end

  defp invalid_path_segment?(segment) when is_binary(segment) do
    segment in ["", ".", ".."] or
      String.contains?(segment, ["%", "/", "\\"]) or
      not String.match?(segment, ~r/\A[A-Za-z0-9_.-]+\z/)
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp handoff_active_overlap(%{active_states: active_states, handoff_states: handoff_states}) do
    active = MapSet.new(Enum.map(active_states || [], &Schema.normalize_issue_state/1))
    handoff = MapSet.new(Enum.map(handoff_states || [], &Schema.normalize_issue_state/1))

    active
    |> MapSet.intersection(handoff)
    |> MapSet.to_list()
  end

  defp unknown_kind_profile(profiles) when is_map(profiles) do
    valid_kinds = [:codex, :claude, :gemini]

    Enum.find_value(profiles, fn {name, profile} ->
      if profile.kind in valid_kinds, do: nil, else: name
    end)
  end

  defp unknown_kind_profile(_), do: nil

  defp invalid_profile_max_concurrent(profiles) when is_map(profiles) do
    Enum.find_value(profiles, fn {name, profile} ->
      case profile.max_concurrent do
        nil -> nil
        value when is_integer(value) and value > 0 -> nil
        _ -> name
      end
    end)
  end

  defp invalid_profile_max_concurrent(_profiles), do: nil

  defp profile_safety_floor_violation(settings) do
    floor = settings.agent.sandbox_safety_floor || %{}

    adapter_for_kind = %{
      codex: SymphonyElixir.Codex.Adapter,
      claude: SymphonyElixir.Claude.Adapter,
      gemini: SymphonyElixir.Gemini.Adapter
    }

    Enum.find_value(settings.profiles, fn {name, profile} ->
      case Map.get(adapter_for_kind, profile.kind) do
        nil ->
          nil

        adapter ->
          kind_floor = Map.get(floor, Atom.to_string(profile.kind), %{})

          if adapter.passes_safety_floor?(profile.config, kind_floor) do
            nil
          else
            name
          end
      end
    end)
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
