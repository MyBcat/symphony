defmodule SymphonyElixir.Config.Schema do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.PathSafety

  @primary_key false

  @type t :: %__MODULE__{}

  defmodule StringOrMap do
    @moduledoc false
    @behaviour Ecto.Type

    @spec type() :: :map
    def type, do: :map

    @spec embed_as(term()) :: :self
    def embed_as(_format), do: :self

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: left == right

    @spec cast(term()) :: {:ok, String.t() | map()} | :error
    def cast(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def cast(_value), do: :error

    @spec load(term()) :: {:ok, String.t() | map()} | :error
    def load(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def load(_value), do: :error

    @spec dump(term()) :: {:ok, String.t() | map()} | :error
    def dump(value) when is_binary(value) or is_map(value), do: {:ok, value}
    def dump(_value), do: :error
  end

  defmodule Tracker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false

    embedded_schema do
      field(:kind, :string)
      field(:endpoint, :string, default: "https://api.monday.com/v2")
      field(:api_token, :string)
      field(:board_id, :integer)
      field(:identifier_prefix, :string, default: "SYM")
      field(:symphony_status_column_id, :string)
      field(:profile_column_id, :string)
      field(:repo_column_id, :string)
      field(:priority_column_id, :string)
      field(:description_column_id, :string)
      field(:branch_column_id, :string)
      field(:labels_column_id, :string)
      field(:pr_column_id, :string)
      field(:heartbeat_item_id, :integer)
      field(:heartbeat_ttl_ms, :integer, default: 60_000)
      field(:complexity_budget_per_tick, :integer, default: 500)
      field(:backoff_factor, :float, default: 2.0)
      field(:max_polling_interval_ms, :integer, default: 60_000)
      field(:failure_ttl_count, :integer, default: 5)
      # Spec M-7 AC3: number of consecutive 5xx/timeout Tracker responses
      # required before the orchestrator logs "outage entry" and pauses new
      # dispatches. The orchestrator never terminates regardless; this only
      # controls when the operator-facing alert fires.
      field(:outage_threshold, :integer, default: 5)
      field(:active_states, {:array, :string}, default: ["Symphony Ready", "In Progress", "Rework"])
      field(:handoff_states, {:array, :string}, default: ["Human Review", "Merging"])
      field(:terminal_states, {:array, :string}, default: ["Done", "Cancelled"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :kind,
          :endpoint,
          :api_token,
          :board_id,
          :identifier_prefix,
          :symphony_status_column_id,
          :profile_column_id,
          :repo_column_id,
          :priority_column_id,
          :description_column_id,
          :branch_column_id,
          :labels_column_id,
          :pr_column_id,
          :heartbeat_item_id,
          :heartbeat_ttl_ms,
          :complexity_budget_per_tick,
          :backoff_factor,
          :max_polling_interval_ms,
          :failure_ttl_count,
          :outage_threshold,
          :active_states,
          :handoff_states,
          :terminal_states
        ],
        empty_values: []
      )
      |> validate_number(:heartbeat_ttl_ms, greater_than: 0)
      |> validate_number(:complexity_budget_per_tick, greater_than: 0)
      |> validate_number(:backoff_factor, greater_than: 1.0)
      |> validate_number(:max_polling_interval_ms, greater_than: 0)
      |> validate_number(:failure_ttl_count, greater_than: 0)
      |> validate_number(:outage_threshold, greater_than: 0)
    end
  end

  defimpl Inspect, for: SymphonyElixir.Config.Schema.Tracker do
    @moduledoc false

    def inspect(tracker, opts) do
      redacted = %{tracker | api_token: redact(tracker.api_token)}
      Inspect.Any.inspect(redacted, opts)
    end

    defp redact(nil), do: nil
    defp redact(""), do: ""

    defp redact(token) when is_binary(token) do
      "<redacted:#{byte_size(token)}_bytes>"
    end

    defp redact(other), do: other
  end

  defmodule Polling do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:interval_ms, :integer, default: 30_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:interval_ms], empty_values: [])
      |> validate_number(:interval_ms, greater_than: 0)
    end
  end

  defmodule Workspace do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:root, :string, default: Path.join(System.tmp_dir!(), "symphony_workspaces"))
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:root], empty_values: [])
    end
  end

  defmodule Worker do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:ssh_hosts, {:array, :string}, default: [])
      field(:max_concurrent_agents_per_host, :integer)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:ssh_hosts, :max_concurrent_agents_per_host], empty_values: [])
      |> validate_number(:max_concurrent_agents_per_host, greater_than: 0)
    end
  end

  defmodule Agent do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    alias SymphonyElixir.Config.Schema

    @primary_key false
    embedded_schema do
      field(:max_concurrent_agents, :integer, default: 10)
      field(:max_turns, :integer, default: 20)
      field(:max_retry_backoff_ms, :integer, default: 300_000)
      field(:max_concurrent_agents_by_state, :map, default: %{})
      field(:default_profile, :string)
      field(:sandbox_safety_floor, :map, default: %{})
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :max_concurrent_agents,
          :max_turns,
          :max_retry_backoff_ms,
          :max_concurrent_agents_by_state,
          :default_profile,
          :sandbox_safety_floor
        ],
        empty_values: []
      )
      |> validate_number(:max_concurrent_agents, greater_than: 0)
      |> validate_number(:max_turns, greater_than: 0)
      |> validate_number(:max_retry_backoff_ms, greater_than: 0)
      |> update_change(:max_concurrent_agents_by_state, &Schema.normalize_state_limits/1)
      |> Schema.validate_state_limits(:max_concurrent_agents_by_state)
    end
  end

  defmodule Codex do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:command, :string, default: "codex exec --json")

      field(:approval_policy, StringOrMap,
        default: %{
          "reject" => %{
            "sandbox_approval" => true,
            "rules" => true,
            "mcp_elicitations" => true
          }
        }
      )

      field(:thread_sandbox, :string, default: "workspace-write")
      field(:turn_sandbox_policy, :map)
      field(:turn_timeout_ms, :integer, default: 3_600_000)
      field(:read_timeout_ms, :integer, default: 5_000)
      field(:stall_timeout_ms, :integer, default: 300_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(
        attrs,
        [
          :command,
          :approval_policy,
          :thread_sandbox,
          :turn_sandbox_policy,
          :turn_timeout_ms,
          :read_timeout_ms,
          :stall_timeout_ms
        ],
        empty_values: []
      )
      |> validate_required([:command])
      |> validate_number(:turn_timeout_ms, greater_than: 0)
      |> validate_number(:read_timeout_ms, greater_than: 0)
      |> validate_number(:stall_timeout_ms, greater_than_or_equal_to: 0)
    end
  end

  defmodule Hooks do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:after_create, :string)
      field(:before_run, :string)
      field(:after_run, :string)
      field(:before_remove, :string)
      field(:timeout_ms, :integer, default: 60_000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:after_create, :before_run, :after_run, :before_remove, :timeout_ms], empty_values: [])
      |> validate_number(:timeout_ms, greater_than: 0)
    end
  end

  defmodule RepoPolicy do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:allowed_clone_hosts, {:array, :string}, default: ["github.com"])
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:allowed_clone_hosts], empty_values: [])
    end
  end

  defmodule RepoEntry do
    @moduledoc false

    # Spec 4 §2.8a default: regex literal that Codex must conclude with for
    # auto-merge to proceed. The shipped Codex review prompt instructs the
    # reviewer to terminate output with this exact phrase on a clean review.
    @default_auto_merge_pass_pattern "NO BLOCKING ISSUES"
    # Spec 4 §2.8a default: PRs with diff line count >= this cap require human
    # review regardless of Codex pass. 500 is the spec-recommended default.
    @default_auto_merge_max_lines 500

    defstruct [
      :key,
      :clone_url,
      :after_create,
      :before_remove,
      :allowed_profiles,
      :default_branch,
      :secrets,
      auto_merge_on_codex_pass: false,
      auto_merge_max_lines: @default_auto_merge_max_lines,
      auto_merge_pass_pattern: @default_auto_merge_pass_pattern
    ]

    @type t :: %__MODULE__{
            key: String.t(),
            clone_url: String.t() | nil,
            after_create: String.t() | nil,
            before_remove: String.t() | nil,
            allowed_profiles: [String.t()] | nil,
            default_branch: String.t() | nil,
            secrets: [String.t()] | nil,
            auto_merge_on_codex_pass: boolean(),
            auto_merge_max_lines: pos_integer(),
            auto_merge_pass_pattern: String.t()
          }

    @doc "Default auto-merge pass-pattern regex literal."
    @spec default_auto_merge_pass_pattern() :: String.t()
    def default_auto_merge_pass_pattern, do: @default_auto_merge_pass_pattern

    @doc "Default auto-merge max-lines cap."
    @spec default_auto_merge_max_lines() :: pos_integer()
    def default_auto_merge_max_lines, do: @default_auto_merge_max_lines
  end

  defmodule Secrets do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Path to the secret_exec.py wrapper. When unset, the resolver falls
      # back to /mnt/d_drive/repos/finances/scripts/secret_exec.py per
      # SYM-11923119480 acceptance criterion §Constraints.
      field(:secret_exec_path, :string)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:secret_exec_path], empty_values: [])
    end
  end

  defmodule Observability do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:dashboard_enabled, :boolean, default: true)
      field(:refresh_ms, :integer, default: 1_000)
      field(:render_interval_ms, :integer, default: 16)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:dashboard_enabled, :refresh_ms, :render_interval_ms], empty_values: [])
      |> validate_number(:refresh_ms, greater_than: 0)
      |> validate_number(:render_interval_ms, greater_than: 0)
    end
  end

  defmodule Server do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:port, :integer)
      field(:host, :string, default: "127.0.0.1")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:port, :host], empty_values: [])
      |> validate_number(:port, greater_than_or_equal_to: 0)
    end
  end

  defmodule Dashboard do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      field(:enabled, :boolean, default: true)
      field(:port, :integer, default: 4000)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:enabled, :port], empty_values: [])
      # M-2 hardening: restrict to valid unprivileged port range. Below 1024
      # would require root; above 65535 is invalid.
      |> validate_number(:port, greater_than_or_equal_to: 1024, less_than_or_equal_to: 65_535)
    end
  end

  defmodule CostCap do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Default `nil` means "no cap configured" so legacy WORKFLOW.md files
      # without a `cost_cap:` block keep dispatching unchanged. Operators
      # opt in to the kill switch by adding `cost_cap.daily_usd: 50` to
      # WORKFLOW.md (the shipped default). Per the SYM-11923119477 spec:
      # "default $50/day" refers to the value in the shipped config, not a
      # mandatory schema default.
      field(:daily_usd, :float, default: nil)
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:daily_usd], empty_values: [])
      |> validate_number(:daily_usd, greater_than: 0.0)
    end
  end

  defmodule PHIGate do
    @moduledoc false
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key false
    embedded_schema do
      # Refuse-default. `strict` flips PHI-tainted items to Cancelled and posts
      # a `## Symphony PHI Refusal` workpad block. `warn` logs and continues
      # dispatch. Operators MUST flip explicitly to `warn` to soften — there
      # is no implicit override.
      field(:mode, :string, default: "strict")
    end

    @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
    def changeset(schema, attrs) do
      schema
      |> cast(attrs, [:mode], empty_values: [])
      |> validate_inclusion(:mode, ["strict", "warn"])
    end
  end

  embedded_schema do
    embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
    embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
    embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
    embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
    embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
    embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
    embeds_one(:repo_policy, RepoPolicy, on_replace: :update, defaults_to_struct: true)
    embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
    embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
    embeds_one(:dashboard, Dashboard, on_replace: :update, defaults_to_struct: true)
    embeds_one(:cost_cap, CostCap, on_replace: :update, defaults_to_struct: true)
    embeds_one(:phi_gate, PHIGate, on_replace: :update, defaults_to_struct: true)
    embeds_one(:secrets, Secrets, on_replace: :update, defaults_to_struct: true)
    field(:profiles, :map, default: %{})
    field(:repos, :map, default: %{})
  end

  @spec parse(map()) :: {:ok, %__MODULE__{}} | {:error, {:invalid_workflow_config, String.t()}}
  def parse(config) when is_map(config) do
    config
    |> normalize_keys()
    |> drop_nil_values()
    |> changeset()
    |> apply_action(:validate)
    |> case do
      {:ok, settings} ->
        {:ok, finalize_settings(settings)}

      {:error, changeset} ->
        {:error, {:invalid_workflow_config, format_errors(changeset)}}
    end
  end

  @spec resolve_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil) :: map()
  def resolve_turn_sandbox_policy(settings, workspace \\ nil) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        policy

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> expand_local_workspace_root()
        |> default_turn_sandbox_policy()
    end
  end

  @spec resolve_runtime_turn_sandbox_policy(%__MODULE__{}, Path.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_runtime_turn_sandbox_policy(settings, workspace \\ nil, opts \\ []) do
    case settings.codex.turn_sandbox_policy do
      %{} = policy ->
        {:ok, policy}

      _ ->
        workspace
        |> default_workspace_root(settings.workspace.root)
        |> default_runtime_turn_sandbox_policy(opts)
    end
  end

  @spec normalize_issue_state(String.t()) :: String.t()
  def normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(state_name)
  end

  @doc false
  @spec normalize_state_limits(nil | map()) :: map()
  def normalize_state_limits(nil), do: %{}

  def normalize_state_limits(limits) when is_map(limits) do
    Enum.reduce(limits, %{}, fn {state_name, limit}, acc ->
      Map.put(acc, normalize_issue_state(to_string(state_name)), limit)
    end)
  end

  @doc false
  @spec validate_state_limits(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def validate_state_limits(changeset, field) do
    validate_change(changeset, field, fn ^field, limits ->
      Enum.flat_map(limits, fn {state_name, limit} ->
        cond do
          to_string(state_name) == "" ->
            [{field, "state names must not be blank"}]

          not is_integer(limit) or limit <= 0 ->
            [{field, "limits must be positive integers"}]

          true ->
            []
        end
      end)
    end)
  end

  defp changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:profiles, :repos])
    |> cast_embed(:tracker, with: &Tracker.changeset/2)
    |> cast_embed(:polling, with: &Polling.changeset/2)
    |> cast_embed(:workspace, with: &Workspace.changeset/2)
    |> cast_embed(:worker, with: &Worker.changeset/2)
    |> cast_embed(:agent, with: &Agent.changeset/2)
    |> cast_embed(:codex, with: &Codex.changeset/2)
    |> cast_embed(:hooks, with: &Hooks.changeset/2)
    |> cast_embed(:repo_policy, with: &RepoPolicy.changeset/2)
    |> cast_embed(:observability, with: &Observability.changeset/2)
    |> cast_embed(:server, with: &Server.changeset/2)
    |> cast_embed(:dashboard, with: &Dashboard.changeset/2)
    |> cast_embed(:cost_cap, with: &CostCap.changeset/2)
    |> cast_embed(:phi_gate, with: &PHIGate.changeset/2)
    |> cast_embed(:secrets, with: &Secrets.changeset/2)
    |> parse_profiles()
    |> parse_repos()
  end

  defp parse_profiles(changeset) do
    case get_change(changeset, :profiles) do
      nil ->
        changeset

      raw_profiles when is_map(raw_profiles) and map_size(raw_profiles) == 0 ->
        changeset

      raw_profiles when is_map(raw_profiles) ->
        parsed =
          Map.new(raw_profiles, fn {name, raw_cfg} ->
            {name, profile_struct(name, raw_cfg)}
          end)

        put_change(changeset, :profiles, parsed)
    end
  end

  defp profile_struct(name, raw_cfg) do
    raw_kind = Map.get(raw_cfg, "kind") || Map.get(raw_cfg, :kind) || ""
    kind = String.to_atom(to_string(raw_kind))

    config =
      raw_cfg
      |> Map.get(Atom.to_string(kind), %{})
      |> normalize_keys()

    %SymphonyElixir.Profile{
      name: name,
      kind: kind,
      max_concurrent: Map.get(raw_cfg, "max_concurrent") || Map.get(raw_cfg, :max_concurrent),
      cost_per_input_token_usd:
        coerce_cost_per_token(
          Map.get(raw_cfg, "cost_per_input_token_usd") ||
            Map.get(raw_cfg, :cost_per_input_token_usd)
        ),
      cost_per_output_token_usd:
        coerce_cost_per_token(
          Map.get(raw_cfg, "cost_per_output_token_usd") ||
            Map.get(raw_cfg, :cost_per_output_token_usd)
        ),
      config: config
    }
  end

  defp coerce_cost_per_token(nil), do: nil

  defp coerce_cost_per_token(value) when is_float(value) and value >= 0.0, do: value

  defp coerce_cost_per_token(value) when is_integer(value) and value >= 0, do: value * 1.0

  defp coerce_cost_per_token(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} when float >= 0.0 -> float
      _ -> :invalid
    end
  end

  defp coerce_cost_per_token(_), do: :invalid

  defp parse_repos(changeset) do
    case get_change(changeset, :repos) do
      nil ->
        changeset

      raw_repos when is_map(raw_repos) and map_size(raw_repos) == 0 ->
        changeset

      raw_repos when is_map(raw_repos) ->
        parsed =
          Map.new(raw_repos, fn {key, raw_cfg} ->
            key = to_string(key)
            {key, repo_entry_struct(key, raw_cfg)}
          end)

        put_change(changeset, :repos, parsed)
    end
  end

  defp repo_entry_struct(key, raw_cfg) when is_map(raw_cfg) do
    cfg = normalize_keys(raw_cfg)

    %RepoEntry{
      key: key,
      clone_url: Map.get(cfg, "clone_url"),
      after_create: Map.get(cfg, "after_create"),
      before_remove: Map.get(cfg, "before_remove"),
      allowed_profiles: normalize_string_list(Map.get(cfg, "allowed_profiles")),
      default_branch: Map.get(cfg, "default_branch"),
      secrets: normalize_string_list(Map.get(cfg, "secrets")),
      auto_merge_on_codex_pass: normalize_auto_merge_flag(Map.get(cfg, "auto_merge_on_codex_pass")),
      auto_merge_max_lines: normalize_auto_merge_max_lines(Map.get(cfg, "auto_merge_max_lines")),
      auto_merge_pass_pattern: normalize_auto_merge_pass_pattern(Map.get(cfg, "auto_merge_pass_pattern"))
    }
  end

  defp repo_entry_struct(key, _raw_cfg) do
    %RepoEntry{key: key}
  end

  # Spec 4 §2.8a: opt-in flag. Default false so unset / non-boolean values
  # never accidentally enable auto-merge. YAML lets the operator write
  # `auto_merge_on_codex_pass: true` without quotes.
  defp normalize_auto_merge_flag(true), do: true
  defp normalize_auto_merge_flag(false), do: false
  defp normalize_auto_merge_flag("true"), do: true
  defp normalize_auto_merge_flag("false"), do: false
  defp normalize_auto_merge_flag(nil), do: false
  defp normalize_auto_merge_flag(_other), do: false

  defp normalize_auto_merge_max_lines(value) when is_integer(value) and value > 0, do: value

  defp normalize_auto_merge_max_lines(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> RepoEntry.default_auto_merge_max_lines()
    end
  end

  defp normalize_auto_merge_max_lines(_other),
    do: RepoEntry.default_auto_merge_max_lines()

  defp normalize_auto_merge_pass_pattern(value) when is_binary(value) and value != "", do: value

  defp normalize_auto_merge_pass_pattern(_other),
    do: RepoEntry.default_auto_merge_pass_pattern()

  defp normalize_string_list(nil), do: nil

  defp normalize_string_list(values) when is_list(values) do
    Enum.map(values, &to_string/1)
  end

  defp normalize_string_list(value), do: value

  defp finalize_settings(settings) do
    tracker = %{
      settings.tracker
      | api_token: resolve_secret_setting(settings.tracker.api_token, System.get_env("MONDAY_API_TOKEN"))
    }

    workspace = %{
      settings.workspace
      | root: resolve_path_value(settings.workspace.root, Path.join(System.tmp_dir!(), "symphony_workspaces"))
    }

    codex = %{
      settings.codex
      | approval_policy: normalize_keys(settings.codex.approval_policy),
        turn_sandbox_policy: normalize_optional_map(settings.codex.turn_sandbox_policy)
    }

    %{settings | tracker: tracker, workspace: workspace, codex: codex}
  end

  defp normalize_keys(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, raw_value}, normalized ->
      Map.put(normalized, normalize_key(key), normalize_keys(raw_value))
    end)
  end

  defp normalize_keys(value) when is_list(value), do: Enum.map(value, &normalize_keys/1)
  defp normalize_keys(value), do: value

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: normalize_keys(value)

  defp normalize_key(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_key(value), do: to_string(value)

  defp drop_nil_values(value) when is_map(value) do
    Enum.reduce(value, %{}, fn {key, nested}, acc ->
      case drop_nil_values(nested) do
        nil -> acc
        normalized -> Map.put(acc, key, normalized)
      end
    end)
  end

  defp drop_nil_values(value) when is_list(value), do: Enum.map(value, &drop_nil_values/1)
  defp drop_nil_values(value), do: value

  defp resolve_secret_setting(nil, fallback), do: normalize_secret_value(fallback)

  defp resolve_secret_setting(value, fallback) when is_binary(value) do
    case resolve_env_value(value, fallback) do
      resolved when is_binary(resolved) -> normalize_secret_value(resolved)
      resolved -> resolved
    end
  end

  defp resolve_path_value(value, default) when is_binary(value) do
    case normalize_path_token(value) do
      :missing ->
        default

      "" ->
        default

      path ->
        path
    end
  end

  defp resolve_env_value(value, fallback) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} ->
        case System.get_env(env_name) do
          nil -> fallback
          "" -> nil
          env_value -> env_value
        end

      :error ->
        value
    end
  end

  defp normalize_path_token(value) when is_binary(value) do
    case env_reference_name(value) do
      {:ok, env_name} -> resolve_env_token(env_name)
      :error -> value
    end
  end

  defp env_reference_name("$" <> env_name) do
    if String.match?(env_name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/) do
      {:ok, env_name}
    else
      :error
    end
  end

  defp env_reference_name(_value), do: :error

  defp resolve_env_token(env_name) do
    case System.get_env(env_name) do
      nil -> :missing
      env_value -> env_value
    end
  end

  defp normalize_secret_value(value) when is_binary(value) do
    if value == "", do: nil, else: value
  end

  defp normalize_secret_value(_value), do: nil

  defp default_turn_sandbox_policy(workspace) do
    %{
      "type" => "workspaceWrite",
      "writableRoots" => [workspace],
      "readOnlyAccess" => %{"type" => "fullAccess"},
      "networkAccess" => false,
      "excludeTmpdirEnvVar" => false,
      "excludeSlashTmp" => false
    }
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, opts) when is_binary(workspace_root) do
    if Keyword.get(opts, :remote, false) do
      {:ok, default_turn_sandbox_policy(workspace_root)}
    else
      with expanded_workspace_root <- expand_local_workspace_root(workspace_root),
           {:ok, canonical_workspace_root} <- PathSafety.canonicalize(expanded_workspace_root) do
        {:ok, default_turn_sandbox_policy(canonical_workspace_root)}
      end
    end
  end

  defp default_runtime_turn_sandbox_policy(workspace_root, _opts) do
    {:error, {:unsafe_turn_sandbox_policy, {:invalid_workspace_root, workspace_root}}}
  end

  defp default_workspace_root(workspace, _fallback) when is_binary(workspace) and workspace != "",
    do: workspace

  defp default_workspace_root(nil, fallback), do: fallback
  defp default_workspace_root("", fallback), do: fallback
  defp default_workspace_root(workspace, _fallback), do: workspace

  defp expand_local_workspace_root(workspace_root)
       when is_binary(workspace_root) and workspace_root != "" do
    Path.expand(workspace_root)
  end

  defp expand_local_workspace_root(_workspace_root) do
    Path.expand(Path.join(System.tmp_dir!(), "symphony_workspaces"))
  end

  defp format_errors(changeset) do
    changeset
    |> traverse_errors(&translate_error/1)
    |> flatten_errors()
    |> Enum.join(", ")
  end

  defp flatten_errors(errors, prefix \\ nil)

  defp flatten_errors(errors, prefix) when is_map(errors) do
    Enum.flat_map(errors, fn {key, value} ->
      next_prefix =
        case prefix do
          nil -> to_string(key)
          current -> current <> "." <> to_string(key)
        end

      flatten_errors(value, next_prefix)
    end)
  end

  defp flatten_errors(errors, prefix) when is_list(errors) do
    Enum.map(errors, &(prefix <> " " <> &1))
  end

  defp translate_error({message, options}) do
    Enum.reduce(options, message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", error_value_to_string(value))
    end)
  end

  defp error_value_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp error_value_to_string(value), do: inspect(value)
end
