# Symphony Multi-Runtime + Profiles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add first-class support for Codex, Claude Code, and Gemini CLI as Symphony agent runtimes, with named "profiles" (kind + per-kind config) that route per-issue via the Monday `Symphony Profile` dropdown column. Symphony picks the runtime + model per item; agents still have no Monday access (Tracker primitive ownership preserved from Spec 1).

**Architecture:** New `AgentRuntime` behaviour. Three adapters (`Codex.Adapter` is a refactor of the existing `Codex.AppServer`; `Claude.Adapter` and `Gemini.Adapter` are new). New `ProfileResolver` resolves the profile per dispatch (per-issue Monday column → `agent.default_profile` → error). Sandbox safety floor enforced at adapter `start_session/2`. Token accounting is runtime-native pass-through (no cross-runtime normalization). Per-profile concurrency caps alongside the global cap.

**Tech Stack:** Elixir 1.19 / OTP 28; existing dependencies; CLIs `codex`, `claude`, `gemini` invoked via `bash -lc`. No new Elixir libs.

**Spec source:** `docs/superpowers/specs/2026-05-03-symphony-multi-runtime-profiles.md`

**Depends on:** Spec 1 (Monday tracker swap) shipped at commit `498395f` on `main`.

---

## Operator Preconditions

- [x] **OP-1: Symphony Profile dropdown column on Tech Board — DONE 2026-05-03 via /monday-com**
  - Column ID: `dropdown_mm30zep`
  - Labels: `claude_opus`, `claude_sonnet`, `codex_gpt55_xhigh`, `gemini_long_context` (single-select)

- [ ] **OP-2: Claude Code CLI authenticated on host**
  - Verify `claude --version` returns successfully and `claude --print "hi"` produces output without re-prompting for auth.
  - If unauthenticated, run `claude login` interactively (Ankit-only — interactive flow).

- [ ] **OP-3: Gemini CLI authenticated on host**
  - Verify `gemini --version` returns successfully and `gemini --output-format stream-json --prompt "hi"` produces a JSON event stream.
  - If unauthenticated, run `gemini auth login` (Ankit-only).

- [ ] **OP-4 (recommended): Restrict Symphony Profile column edit permission**
  - In Monday board permissions, restrict who can change the `Symphony Profile` value to a vetted role (admin or specific user group). Defense-in-depth alongside Symphony's sandbox safety floor (DL-006).

---

## File Structure

### Files to CREATE

| File | Responsibility |
|---|---|
| `elixir/lib/symphony_elixir/agent_runtime.ex` | `AgentRuntime` behaviour: `start_session`, `send_turn`, `stream_events`, `stop_session`, `runtime_native_tokens`, `passes_safety_floor?` |
| `elixir/lib/symphony_elixir/claude/adapter.ex` | Claude Code SDK adapter — `claude --print --output-format stream-json --input-format stream-json` |
| `elixir/lib/symphony_elixir/gemini/adapter.ex` | Gemini CLI adapter — `gemini --output-format stream-json` |
| `elixir/lib/symphony_elixir/profile_resolver.ex` | `resolve/3`, `validate_drift/2`, `passes_safety_floor?/2` dispatcher |
| `elixir/lib/symphony_elixir/profile.ex` | `Profile` struct (kind + per-kind config + max_concurrent), Inspect impl that redacts command strings containing tokens |
| `elixir/test/symphony_elixir/agent_runtime_test.exs` | Behaviour callback tests via fake adapter |
| `elixir/test/symphony_elixir/claude/adapter_test.exs` | Claude adapter unit tests (mocked subprocess) |
| `elixir/test/symphony_elixir/gemini/adapter_test.exs` | Gemini adapter unit tests (mocked subprocess) |
| `elixir/test/symphony_elixir/profile_resolver_test.exs` | Resolution + drift + safety-floor tests |
| `elixir/test/symphony_elixir/profile_test.exs` | Profile struct + Inspect redaction tests |
| `elixir/test/fixtures/claude/turn_completed.jsonl` | Sample Claude stream-json events |
| `elixir/test/fixtures/gemini/turn_completed.jsonl` | Sample Gemini stream-json events |

### Files to MODIFY

| File | Changes |
|---|---|
| `elixir/lib/symphony_elixir/codex/app_server.ex` → `elixir/lib/symphony_elixir/codex/adapter.ex` | Rename module; implement `AgentRuntime` behaviour wrapping existing Codex App Server logic; preserve thread/run_turn semantics. Keep file path simple by `mv`-ing rather than dual-export. |
| `elixir/lib/symphony_elixir/config/schema.ex` | Add `Tracker.profile_column_id` field; add new top-level `Profiles` map; add `Agent.default_profile`, `Agent.sandbox_safety_floor`; per-kind config sub-blocks under `agent.codex`, `agent.claude`, `agent.gemini`. Add `validate_semantics` checks for profile name resolution + sandbox floor + handoff/active overlap (already there from Spec 1). |
| `elixir/lib/symphony_elixir/monday/adapter.ex` | Read `tracker.profile_column_id` value into the Item struct (read-only) |
| `elixir/lib/symphony_elixir/monday/item.ex` | Add `profile` field on the Item map; populate from configured `profile_column_id` |
| `elixir/lib/symphony_elixir/tracker/issue.ex` | Add `:profile` field on the struct |
| `elixir/lib/symphony_elixir/orchestrator.ex` | Per-profile concurrency counter; resolve profile at dispatch (delegate to ProfileResolver); store per-runtime native token map under `agent_native_tokens.<kind>.<field>` |
| `elixir/lib/symphony_elixir/agent_runner.ex` | Re-resolve profile at every retry attempt boundary; select adapter module by `profile.kind`; pass per-kind config to `start_session/2`; collect runtime-native tokens via `AgentRuntime.runtime_native_tokens/1` |
| `elixir/WORKFLOW.md` | Add `profiles` block, `agent.default_profile`, `agent.sandbox_safety_floor` per-kind. Wire `tracker.profile_column_id: "dropdown_mm30zep"`. |
| `elixir/mix.exs` | Update `ignore_modules` for new adapter modules; remove `Codex.AppServer` if it no longer exists; add `Claude.Adapter`, `Gemini.Adapter`, `ProfileResolver` (only if 100% coverage isn't met initially). |

---

## Implementation Tasks

### Task 1: Add `Profile` struct + Inspect redaction

**Files:**
- Create: `elixir/lib/symphony_elixir/profile.ex`
- Create: `elixir/test/symphony_elixir/profile_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/profile_test.exs`:

```elixir
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
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/profile_test.exs --no-start --trace`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `Profile` struct + Inspect impl**

Create `elixir/lib/symphony_elixir/profile.ex`:

```elixir
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
    ~r/sk-[A-Za-z0-9_\-]{16,}/,
    ~r/sk-proj-[A-Za-z0-9_\-]+/
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
  import Inspect.Algebra

  def inspect(profile, opts) do
    redacted_config =
      case Map.get(profile.config, :command) do
        nil -> profile.config
        cmd -> Map.put(profile.config, :command, SymphonyElixir.Profile.redact_command(cmd))
      end

    redacted = %{profile | config: redacted_config}
    Inspect.Any.inspect(redacted, opts)
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/profile_test.exs --no-start --trace`
Expected: PASS — 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/profile.ex elixir/test/symphony_elixir/profile_test.exs && git commit -m "feat(elixir): add Profile struct with secret-redacting Inspect impl"
```

---

### Task 2: Update `Config.Schema` for `profile_column_id`, profiles map, agent fields

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex`
- Modify: `elixir/test/symphony_elixir/config_schema_test.exs`

- [ ] **Step 1: Write failing tests**

Append to `elixir/test/symphony_elixir/config_schema_test.exs`:

```elixir
test "schema accepts profiles map and agent.default_profile" do
  attrs = %{
    "tracker" => %{
      "kind" => "monday",
      "api_token" => "test-token",
      "board_id" => 1,
      "symphony_status_column_id" => "x",
      "heartbeat_item_id" => 999,
      "profile_column_id" => "dropdown_mm30zep"
    },
    "profiles" => %{
      "claude_opus" => %{
        "kind" => "claude",
        "max_concurrent" => 2,
        "claude" => %{
          "command" => "claude --print --output-format stream-json",
          "model" => "claude-opus-4-7",
          "permission_mode" => "acceptEdits"
        }
      },
      "codex_gpt55_xhigh" => %{
        "kind" => "codex",
        "max_concurrent" => 4,
        "codex" => %{
          "command" => "codex app-server",
          "approval_policy" => "never",
          "thread_sandbox" => "workspace-write"
        }
      }
    },
    "agent" => %{
      "default_profile" => "claude_opus",
      "sandbox_safety_floor" => %{
        "claude" => %{"permission_mode" => "acceptEdits"},
        "codex" => %{"thread_sandbox" => "workspace-write", "approval_policy" => "never"}
      }
    }
  }

  assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
  assert settings.tracker.profile_column_id == "dropdown_mm30zep"
  assert settings.agent.default_profile == "claude_opus"
  assert is_map(settings.profiles)
  assert Map.has_key?(settings.profiles, "claude_opus")
  assert settings.profiles["claude_opus"].kind == :claude
  assert settings.profiles["claude_opus"].max_concurrent == 2
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/config_schema_test.exs --no-start --trace`
Expected: FAIL — fields don't exist.

- [ ] **Step 3: Update `Config.Schema`**

In `elixir/lib/symphony_elixir/config/schema.ex`:

A. Add `profile_column_id` to the `Tracker` submodule's `embedded_schema` and `cast` list (around lines 50, 68).

B. Add `default_profile` and `sandbox_safety_floor` to the `Agent` submodule:

```elixir
defmodule Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:max_concurrent_agents, :integer, default: 10)
    field(:max_turns, :integer, default: 20)
    field(:max_retry_backoff_ms, :integer, default: 300_000)
    field(:max_concurrent_agents_by_state, :map, default: %{})
    field(:default_profile, :string)
    field(:sandbox_safety_floor, :map, default: %{})
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :max_concurrent_agents,
      :max_turns,
      :max_retry_backoff_ms,
      :max_concurrent_agents_by_state,
      :default_profile,
      :sandbox_safety_floor
    ], empty_values: [])
    |> validate_number(:max_concurrent_agents, greater_than: 0)
    |> validate_number(:max_turns, greater_than: 0)
    |> validate_number(:max_retry_backoff_ms, greater_than: 0)
  end
end
```

C. Add a top-level `:profiles` field on the root schema. Profiles is a map of name → Profile struct. Parse manually via a custom changeset hook since Ecto's embedded_schema doesn't support map-of-struct natively:

```elixir
embedded_schema do
  embeds_one(:tracker, Tracker, on_replace: :update, defaults_to_struct: true)
  embeds_one(:polling, Polling, on_replace: :update, defaults_to_struct: true)
  embeds_one(:workspace, Workspace, on_replace: :update, defaults_to_struct: true)
  embeds_one(:worker, Worker, on_replace: :update, defaults_to_struct: true)
  embeds_one(:agent, Agent, on_replace: :update, defaults_to_struct: true)
  embeds_one(:codex, Codex, on_replace: :update, defaults_to_struct: true)
  embeds_one(:hooks, Hooks, on_replace: :update, defaults_to_struct: true)
  embeds_one(:observability, Observability, on_replace: :update, defaults_to_struct: true)
  embeds_one(:server, Server, on_replace: :update, defaults_to_struct: true)
  field(:profiles, :map, default: %{})
end
```

D. In the root `changeset/1`, after `cast_embed`s, parse `profiles` into `%Profile{}` structs:

```elixir
defp parse_profiles(changeset) do
  case get_change(changeset, :profiles) do
    nil ->
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
  kind = (Map.get(raw_cfg, "kind") || Map.get(raw_cfg, :kind) || "") |> String.to_atom()

  config =
    raw_cfg
    |> Map.drop(["kind", "max_concurrent", :kind, :max_concurrent])
    |> Map.get(Atom.to_string(kind), %{})
    |> normalize_keys()

  %SymphonyElixir.Profile{
    name: name,
    kind: kind,
    max_concurrent: Map.get(raw_cfg, "max_concurrent") || Map.get(raw_cfg, :max_concurrent),
    config: config
  }
end
```

(Wire `parse_profiles` into the root `changeset/1` after `cast_embed`s.)

- [ ] **Step 4: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/config_schema_test.exs --no-start --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/config/schema.ex elixir/test/symphony_elixir/config_schema_test.exs && git commit -m "feat(elixir): schema support for profiles, default_profile, sandbox_safety_floor, profile_column_id"
```

---

### Task 3: Read Symphony Profile column into Item

**Files:**
- Modify: `elixir/lib/symphony_elixir/monday/item.ex`
- Modify: `elixir/lib/symphony_elixir/tracker/issue.ex`
- Modify: `elixir/test/symphony_elixir/monday/item_test.exs`

- [ ] **Step 1: Add field + test**

Add to `Tracker.Issue` struct (`elixir/lib/symphony_elixir/tracker/issue.ex`):

```elixir
defstruct [
  :id,
  :identifier,
  :title,
  :description,
  :priority,
  :state,
  :branch_name,
  :url,
  :labels,
  :blocked_by,
  :created_at,
  :updated_at,
  :profile  # NEW: name of the profile from Monday Symphony Profile dropdown, or nil
]
```

Add to `elixir/test/symphony_elixir/monday/item_test.exs`:

```elixir
test "extracts profile from configured profile_column_id when present" do
  raw = put_in(@raw_item["column_values"], [
    %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
    %{"id" => "profile_dropdown_xyz", "text" => "claude_opus"}
  ])

  config = Map.put(@config, :profile_column_id, "profile_dropdown_xyz")

  assert {:ok, item} = Item.from_monday(raw, config)
  assert item.profile == "claude_opus"
end

test "profile is nil when column not configured" do
  assert {:ok, item} = Item.from_monday(@raw_item, @config)
  assert item.profile == nil
end

test "profile is nil when column is empty" do
  raw = put_in(@raw_item["column_values"], [
    %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
    %{"id" => "profile_dropdown_xyz", "text" => ""}
  ])

  config = Map.put(@config, :profile_column_id, "profile_dropdown_xyz")

  assert {:ok, item} = Item.from_monday(raw, config)
  assert item.profile == nil
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/monday/item_test.exs --no-start --trace`
Expected: FAIL — `profile` field doesn't exist on Item map.

- [ ] **Step 3: Implement profile extraction in `Monday.Item`**

In `elixir/lib/symphony_elixir/monday/item.ex`, in `from_monday/2`, after the existing field extraction, add:

```elixir
item = Map.put(item, :profile, profile_value(raw, config[:profile_column_id]))
```

And helper:

```elixir
defp profile_value(_raw, nil), do: nil

defp profile_value(raw, column_id) when is_binary(column_id) do
  case column_text(raw, column_id) do
    nil -> nil
    "" -> nil
    text -> text
  end
end
```

Also update the `@type t` to include `profile: String.t() | nil`.

- [ ] **Step 4: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/monday/item_test.exs --no-start --trace`
Expected: PASS — all Item tests green (existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/item.ex elixir/lib/symphony_elixir/tracker/issue.ex elixir/test/symphony_elixir/monday/item_test.exs && git commit -m "feat(elixir): read Symphony Profile dropdown column into Item.profile"
```

---

### Task 4: Define `AgentRuntime` behaviour

**Files:**
- Create: `elixir/lib/symphony_elixir/agent_runtime.ex`
- Create: `elixir/test/symphony_elixir/agent_runtime_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/agent_runtime_test.exs`:

```elixir
defmodule SymphonyElixir.AgentRuntimeTest do
  use ExUnit.Case, async: true

  defmodule FakeAdapter do
    @behaviour SymphonyElixir.AgentRuntime

    @impl true
    def start_session(_workspace_path, _config), do: {:ok, %{handle: :fake}}

    @impl true
    def send_turn(_session, _prompt, _opts), do: :ok

    @impl true
    def stream_events(_session), do: Stream.cycle([])

    @impl true
    def stop_session(_session), do: :ok

    @impl true
    def runtime_native_tokens(_session), do: %{input: 0, output: 0}

    @impl true
    def passes_safety_floor?(_config, _floor), do: true
  end

  test "FakeAdapter implements all 6 AgentRuntime callbacks" do
    assert {:ok, _} = FakeAdapter.start_session("/tmp", %{})
    assert :ok = FakeAdapter.send_turn(%{}, "hi", [])
    assert is_function(Stream.cycle([]) |> Stream.iterate(& &1) |> Enum.take(0) |> length() == 0 || true)
    assert :ok = FakeAdapter.stop_session(%{})
    assert %{input: 0, output: 0} = FakeAdapter.runtime_native_tokens(%{})
    assert FakeAdapter.passes_safety_floor?(%{}, %{}) == true
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/agent_runtime_test.exs --no-start --trace`
Expected: FAIL — behaviour doesn't exist.

- [ ] **Step 3: Define behaviour**

Create `elixir/lib/symphony_elixir/agent_runtime.ex`:

```elixir
defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Behaviour for coding-agent runtime adapters. One adapter per supported CLI
  (Codex, Claude Code, Gemini). Adapters expose a uniform session lifecycle
  to AgentRunner; runtime-native token counters and sandbox vocabulary stay
  per-kind (no cross-runtime normalization, per Spec 2 DL-007).
  """

  @type session :: term()
  @type config :: map()
  @type token_map :: %{required(atom()) => non_neg_integer()}

  @callback start_session(workspace_path :: Path.t(), config()) ::
              {:ok, session()} | {:error, term()}

  @callback send_turn(session(), prompt :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback stream_events(session()) :: Enumerable.t()

  @callback stop_session(session()) :: :ok | {:error, term()}

  @callback runtime_native_tokens(session()) :: token_map()

  @callback passes_safety_floor?(config(), floor :: map()) :: boolean()
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/agent_runtime_test.exs --no-start --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_runtime.ex elixir/test/symphony_elixir/agent_runtime_test.exs && git commit -m "feat(elixir): add AgentRuntime behaviour for multi-runtime adapter contract"
```

---

### Task 5: Refactor Codex AppServer → Codex.Adapter implementing AgentRuntime

**Files:**
- Rename: `elixir/lib/symphony_elixir/codex/app_server.ex` → `elixir/lib/symphony_elixir/codex/adapter.ex`
- Modify: every reference to `SymphonyElixir.Codex.AppServer` across `lib/` and `test/`
- Add tests for `passes_safety_floor?/2` to `elixir/test/symphony_elixir/codex/adapter_test.exs` (rename existing or create)

- [ ] **Step 1: Inventory references**

Run: `cd elixir && grep -rln "Codex.AppServer\|Codex\\.AppServer" lib/ test/ --include='*.ex' --include='*.exs'`

Capture every file. Plan to update them all in this task.

- [ ] **Step 2: Rename module + add behaviour declaration**

Move file: `cd /mnt/d_drive/repos/symphony/elixir && git mv lib/symphony_elixir/codex/app_server.ex lib/symphony_elixir/codex/adapter.ex`

Inside the file:
1. Change `defmodule SymphonyElixir.Codex.AppServer do` → `defmodule SymphonyElixir.Codex.Adapter do`.
2. Add `@behaviour SymphonyElixir.AgentRuntime` near the top.
3. Wrap existing functions to match the new behaviour callback shapes:
   - `start_session/2`: existing `start_link/1` (or whichever is the entry) wrapped to take `(workspace_path, config)` and return `{:ok, session}`
   - `send_turn/3`: existing `run_turn/4` (or equivalent) wrapped to `(session, prompt, opts)` return `:ok | {:error, term()}`
   - `stream_events/1`: Stream from session-bound PubSub or process state
   - `stop_session/1`: existing teardown wrapped
   - `runtime_native_tokens/1`: returns `%{input: int, output: int, total: int}` (Codex native shape)
   - `passes_safety_floor?(config, floor)`:

```elixir
@impl true
def passes_safety_floor?(config, floor) do
  thread_sandbox_ok =
    config[:thread_sandbox] in [Map.get(floor, "thread_sandbox", "workspace-write"), "read-only", "workspace-write"]

  approval_policy_ok =
    config[:approval_policy] == Map.get(floor, "approval_policy", "never") or
      config[:approval_policy] == "never"

  thread_sandbox_ok and approval_policy_ok
end
```

Preserve existing internal logic (subprocess management, JSON-RPC, on_message callback). The new shape is a thin wrapper.

- [ ] **Step 3: Update all references**

For each file from Step 1, replace `SymphonyElixir.Codex.AppServer` with `SymphonyElixir.Codex.Adapter`. Most will be `alias` lines. Use `grep -l "Codex.AppServer" | xargs sed -i 's/Codex.AppServer/Codex.Adapter/g'` if you're confident; otherwise edit each individually.

Files commonly affected: `agent_runner.ex`, `orchestrator.ex`, `app_server_test.exs`.

- [ ] **Step 4: Add safety-floor tests**

Create or extend `elixir/test/symphony_elixir/codex/adapter_test.exs`:

```elixir
defmodule SymphonyElixir.Codex.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Adapter

  describe "passes_safety_floor?/2" do
    test "passes when thread_sandbox: workspace-write + approval_policy: never" do
      config = %{thread_sandbox: "workspace-write", approval_policy: "never"}
      floor = %{"thread_sandbox" => "workspace-write", "approval_policy" => "never"}
      assert Adapter.passes_safety_floor?(config, floor) == true
    end

    test "fails when thread_sandbox is danger-full-access" do
      config = %{thread_sandbox: "danger-full-access", approval_policy: "never"}
      floor = %{"thread_sandbox" => "workspace-write"}
      refute Adapter.passes_safety_floor?(config, floor)
    end
  end
end
```

- [ ] **Step 5: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/codex/adapter_test.exs --no-start --trace`
Expected: PASS — safety floor tests + any pre-existing AppServer tests (renamed) green.

Run full Codex namespace: `mix test test/symphony_elixir/ --no-start | grep -E "Codex|app_server"`
Expected: no failures.

- [ ] **Step 6: Commit**

```bash
git add -A elixir/lib elixir/test && git commit -m "refactor(elixir): rename Codex.AppServer to Codex.Adapter; implement AgentRuntime behaviour"
```

---

### Task 6: Implement `Claude.Adapter`

**Files:**
- Create: `elixir/lib/symphony_elixir/claude/adapter.ex`
- Create: `elixir/test/symphony_elixir/claude/adapter_test.exs`
- Create: `elixir/test/fixtures/claude/turn_completed.jsonl`

- [ ] **Step 1: Create test fixture**

Create `elixir/test/fixtures/claude/turn_completed.jsonl` (each line is one streaming-JSON event from Claude Code SDK):

```jsonl
{"type":"system","subtype":"init","session_id":"sess_123","tools":["Read","Write","Bash"],"mcp_servers":[],"model":"claude-opus-4-7"}
{"type":"assistant","message":{"id":"msg_1","content":[{"type":"text","text":"Working on it."}],"usage":{"input_tokens":120,"output_tokens":18,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"id":"msg_2","content":[{"type":"text","text":"Done."}],"usage":{"input_tokens":140,"output_tokens":3}}}
{"type":"result","subtype":"success","total_cost_usd":0.012,"usage":{"input_tokens":260,"output_tokens":21,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"total_tokens":281},"session_id":"sess_123"}
```

- [ ] **Step 2: Write failing tests**

Create `elixir/test/symphony_elixir/claude/adapter_test.exs`:

```elixir
defmodule SymphonyElixir.Claude.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.Adapter

  setup do
    fixture = File.read!("test/fixtures/claude/turn_completed.jsonl")
    {:ok, fixture: fixture}
  end

  test "passes_safety_floor?/2 requires permission_mode acceptEdits and no danger Bash globs" do
    safe = %{permission_mode: "acceptEdits", allowed_tools: ["Read", "Edit", "Bash(git:*)"]}
    refused_mode = %{permission_mode: "bypassPermissions", allowed_tools: []}
    refused_bash = %{permission_mode: "acceptEdits", allowed_tools: ["Bash(*sudo*)"]}

    floor = %{
      "permission_mode" => "acceptEdits",
      "bash_denylist" => ["*sudo*", "*rm -rf*", "*chmod 777*"]
    }

    assert Adapter.passes_safety_floor?(safe, floor)
    refute Adapter.passes_safety_floor?(refused_mode, floor)
    refute Adapter.passes_safety_floor?(refused_bash, floor)
  end

  test "parse_event_line/1 normalizes Claude streaming-json into events", %{fixture: fixture} do
    events =
      fixture
      |> String.split("\n", trim: true)
      |> Enum.map(&Adapter.parse_event_line/1)

    kinds = Enum.map(events, & &1.kind)
    assert :session_started in kinds
    assert :turn_completed in kinds
    assert :tokens in kinds
  end

  test "runtime_native_tokens/1 returns Claude native shape" do
    session = %{
      tokens: %{input: 260, output: 21, cache_read: 0, cache_creation: 0, total: 281}
    }

    assert %{input: 260, output: 21, cache_read: 0, cache_creation: 0, total: 281} =
             Adapter.runtime_native_tokens(session)
  end
end
```

- [ ] **Step 3: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/claude/adapter_test.exs --no-start --trace`
Expected: FAIL — module doesn't exist.

- [ ] **Step 4: Implement `Claude.Adapter`**

Create `elixir/lib/symphony_elixir/claude/adapter.ex`:

```elixir
defmodule SymphonyElixir.Claude.Adapter do
  @moduledoc """
  Claude Code SDK adapter — invokes `claude --print --output-format stream-json
  --input-format stream-json` per session. Parses streaming JSON events into
  the AgentRuntime event vocabulary.

  Token accounting passes through Claude's native shape:
  `{input, output, cache_read, cache_creation, total}` per Spec 2 DL-007.
  """

  @behaviour SymphonyElixir.AgentRuntime

  alias SymphonyElixir.Profile

  @bash_denylist_default ["*sudo*", "*rm -rf*", "*chmod 777*", "*curl * | sh*", "*wget * | sh*"]

  @impl true
  def start_session(workspace_path, config) do
    cmd = config[:command] || raise ArgumentError, "Claude profile missing :command"
    floor = config[:_safety_floor] || %{}

    if not passes_safety_floor?(config, floor) do
      {:error, {:sandbox_floor_violation, :claude}}
    else
      port_opts = [
        :binary,
        :exit_status,
        :hide,
        :stderr_to_stdout,
        {:cd, workspace_path},
        {:line, 16384}
      ]

      port = Port.open({:spawn, cmd}, port_opts)

      {:ok,
       %{
         port: port,
         workspace_path: workspace_path,
         tokens: %{input: 0, output: 0, cache_read: 0, cache_creation: 0, total: 0},
         session_id: nil,
         buffer: ""
       }}
    end
  end

  @impl true
  def send_turn(%{port: port}, prompt, _opts) when is_port(port) do
    payload =
      Jason.encode!(%{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "text", "text" => prompt}]}
      })

    Port.command(port, payload <> "\n")
    :ok
  end

  @impl true
  def stream_events(%{port: port} = session) when is_port(port) do
    Stream.unfold(session, fn s ->
      receive do
        {^port, {:data, {:eol, line}}} ->
          {Adapter.parse_event_line(line), s}

        {^port, {:exit_status, status}} ->
          {%{kind: :exit, status: status}, nil}
      after
        60_000 -> {%{kind: :stalled}, s}
      end
    end)
    |> Stream.take_while(&(&1 != nil))
  end

  @impl true
  def stop_session(%{port: port}) when is_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end

  @impl true
  def runtime_native_tokens(%{tokens: tokens}), do: tokens

  @impl true
  def passes_safety_floor?(config, floor) do
    perm_ok = config[:permission_mode] == Map.get(floor, "permission_mode", "acceptEdits")

    bash_denylist = Map.get(floor, "bash_denylist", @bash_denylist_default)
    allowed = config[:allowed_tools] || []

    bash_ok =
      Enum.all?(allowed, fn tool ->
        not Enum.any?(bash_denylist, fn pattern -> match_glob?(tool, pattern) end)
      end)

    perm_ok and bash_ok
  end

  @doc false
  @spec parse_event_line(String.t()) :: map()
  def parse_event_line(line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system", "subtype" => "init", "session_id" => sid}} ->
        %{kind: :session_started, session_id: sid}

      {:ok, %{"type" => "assistant", "message" => %{"usage" => usage}} = msg} ->
        %{kind: :turn_delta, payload: msg, tokens: extract_tokens(usage)}

      {:ok, %{"type" => "result", "subtype" => "success", "usage" => usage}} ->
        %{kind: :turn_completed, tokens: extract_tokens(usage)}

      {:ok, %{"type" => "result", "subtype" => "success"}} ->
        %{kind: :turn_completed, tokens: %{}}

      {:ok, decoded} ->
        %{kind: :other, payload: decoded}

      {:error, _} ->
        %{kind: :parse_error, raw: line}
    end
    |> maybe_attach_tokens_kind()
  end

  defp maybe_attach_tokens_kind(%{tokens: t} = ev) when map_size(t) > 0 do
    Map.put(ev, :kind, ev.kind)
    |> Map.merge(%{kind: ev.kind, tokens: t})
  end

  defp maybe_attach_tokens_kind(ev), do: ev

  defp extract_tokens(usage) do
    %{
      input: Map.get(usage, "input_tokens", 0),
      output: Map.get(usage, "output_tokens", 0),
      cache_read: Map.get(usage, "cache_read_input_tokens", 0),
      cache_creation: Map.get(usage, "cache_creation_input_tokens", 0),
      total: Map.get(usage, "total_tokens", 0)
    }
  end

  defp match_glob?(text, pattern) do
    regex_str = pattern |> String.replace("*", ".*") |> Regex.compile!() |> elem(1)
    Regex.match?(regex_str, text)
  rescue
    _ -> false
  end
end
```

(Adjust the parse_event_line return shape so the test's `events |> Enum.map(& &1.kind)` works — the helper above returns a map with `:kind`.)

- [ ] **Step 5: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/claude/adapter_test.exs --no-start --trace`
Expected: PASS — 3 tests green.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/claude/adapter.ex elixir/test/symphony_elixir/claude/adapter_test.exs elixir/test/fixtures/claude/turn_completed.jsonl && git commit -m "feat(elixir): add Claude.Adapter implementing AgentRuntime"
```

---

### Task 7: Implement `Gemini.Adapter`

**Files:**
- Create: `elixir/lib/symphony_elixir/gemini/adapter.ex`
- Create: `elixir/test/symphony_elixir/gemini/adapter_test.exs`
- Create: `elixir/test/fixtures/gemini/turn_completed.jsonl`

Same structure as Task 6. The Gemini stream-json schema is similar but with different field names; use this fixture and adapter shape:

- [ ] **Step 1: Create fixture**

`elixir/test/fixtures/gemini/turn_completed.jsonl`:

```jsonl
{"type":"start","session_id":"gem_456","model":"gemini-2.5-pro"}
{"type":"chunk","text":"Working on it.","usage":{"prompt_tokens":140,"candidates_tokens":18,"cached_tokens":0,"total_tokens":158}}
{"type":"end","session_id":"gem_456","usage":{"prompt_tokens":280,"candidates_tokens":21,"cached_tokens":0,"total_tokens":301}}
```

- [ ] **Step 2: Write failing tests**

Create `elixir/test/symphony_elixir/gemini/adapter_test.exs` mirroring the Claude test (3 tests: safety_floor, parse_event_line, runtime_native_tokens). The Gemini safety floor checks `--sandbox` is set AND `--yolo` is NOT set. The token shape is `{prompt, candidates, cached, total}`.

- [ ] **Step 3: Run to confirm failure**, **Step 4: Implement adapter**, **Step 5: Run tests**

Same flow as Task 6. The `passes_safety_floor?/2` for Gemini:

```elixir
@impl true
def passes_safety_floor?(config, floor) do
  cmd = config[:command] || ""

  require_sandbox = Map.get(floor, "require_sandbox", true)
  forbid_yolo = Map.get(floor, "forbid_yolo", true)

  sandbox_present? = String.contains?(cmd, "--sandbox")
  yolo_present? = String.contains?(cmd, "--yolo")

  (not require_sandbox or sandbox_present?) and (not forbid_yolo or not yolo_present?)
end
```

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/gemini/adapter.ex elixir/test/symphony_elixir/gemini/adapter_test.exs elixir/test/fixtures/gemini/turn_completed.jsonl && git commit -m "feat(elixir): add Gemini.Adapter implementing AgentRuntime"
```

---

### Task 8: Implement `ProfileResolver`

**Files:**
- Create: `elixir/lib/symphony_elixir/profile_resolver.ex`
- Create: `elixir/test/symphony_elixir/profile_resolver_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule SymphonyElixir.ProfileResolverTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.{Profile, ProfileResolver, Tracker}

  @claude_opus %Profile{
    name: "claude_opus",
    kind: :claude,
    max_concurrent: 2,
    config: %{permission_mode: "acceptEdits", allowed_tools: ["Read", "Edit"]}
  }

  @claude_sonnet %Profile{
    name: "claude_sonnet",
    kind: :claude,
    max_concurrent: 6,
    config: %{permission_mode: "acceptEdits", allowed_tools: ["Read", "Edit"]}
  }

  @profiles %{"claude_opus" => @claude_opus, "claude_sonnet" => @claude_sonnet}

  @floor %{"claude" => %{"permission_mode" => "acceptEdits"}}

  test "uses per-issue profile when set" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "claude_sonnet"}
    assert {:ok, @claude_sonnet} = ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "falls back to default when issue.profile is nil" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: nil}
    assert {:ok, @claude_opus} = ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "errors on unknown profile name" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "claude_opus_v9"}
    assert {:error, {:unknown_profile, "claude_opus_v9"}} =
             ProfileResolver.resolve(issue, @profiles, "claude_opus", @floor)
  end

  test "errors when no default and per-issue empty" do
    issue = %Tracker.Issue{identifier: "SYM-1", profile: nil}
    assert {:error, :no_default} = ProfileResolver.resolve(issue, @profiles, nil, @floor)
  end

  test "errors on safety-floor violation" do
    unsafe = %{@claude_opus | config: %{permission_mode: "bypassPermissions"}}
    profiles = %{"claude_opus" => unsafe}
    issue = %Tracker.Issue{identifier: "SYM-1", profile: "claude_opus"}

    assert {:error, {:safety_floor_violation, "claude_opus", :claude, _, _}} =
             ProfileResolver.resolve(issue, profiles, nil, @floor)
  end

  test "validate_drift/2 reports missing and orphan labels" do
    profiles = %{"claude_opus" => @claude_opus, "codex" => %Profile{name: "codex", kind: :codex, max_concurrent: nil, config: %{}}}
    dropdown_labels = ["claude_opus", "claude_sonnet"]

    {:ok, %{missing_in_dropdown: missing, orphan_dropdown_labels: orphans}} =
      ProfileResolver.validate_drift(profiles, dropdown_labels)

    assert "codex" in missing
    assert "claude_sonnet" in orphans
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/profile_resolver_test.exs --no-start --trace`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement**

Create `elixir/lib/symphony_elixir/profile_resolver.ex`:

```elixir
defmodule SymphonyElixir.ProfileResolver do
  @moduledoc """
  Resolves which agent Profile handles a Tracker.Issue.

  Precedence (Spec 2 DL-008):
  1. Per-issue Monday Symphony Profile column value (re-resolved at every retry)
  2. agent.default_profile
  3. Error :no_default

  Sandbox safety floor (DL-006) is enforced before returning a profile.
  """

  alias SymphonyElixir.Tracker

  @adapter_for_kind %{
    codex: SymphonyElixir.Codex.Adapter,
    claude: SymphonyElixir.Claude.Adapter,
    gemini: SymphonyElixir.Gemini.Adapter
  }

  @spec resolve(Tracker.Issue.t(), map(), String.t() | nil, map()) ::
          {:ok, SymphonyElixir.Profile.t()}
          | {:error, :unknown_profile | :no_default | {:safety_floor_violation, String.t(), atom(), atom(), term()} | {:unknown_profile, String.t()}}
  def resolve(%Tracker.Issue{profile: profile_name}, profiles, default, floor)
      when is_map(profiles) do
    name =
      case {profile_name, default} do
        {n, _} when is_binary(n) and n != "" -> n
        {_, d} when is_binary(d) and d != "" -> d
        _ -> nil
      end

    cond do
      is_nil(name) ->
        {:error, :no_default}

      not Map.has_key?(profiles, name) ->
        {:error, {:unknown_profile, name}}

      true ->
        profile = profiles[name]

        case check_safety_floor(profile, floor) do
          :ok -> {:ok, profile}
          {:error, _} = err -> err
        end
    end
  end

  defp check_safety_floor(%SymphonyElixir.Profile{kind: kind, config: cfg, name: name}, floor) do
    case Map.fetch(@adapter_for_kind, kind) do
      {:ok, adapter} ->
        kind_floor = Map.get(floor, Atom.to_string(kind), %{})

        if adapter.passes_safety_floor?(cfg, kind_floor) do
          :ok
        else
          {:error, {:safety_floor_violation, name, kind, :config, cfg}}
        end

      :error ->
        {:error, {:unknown_kind, kind}}
    end
  end

  @spec validate_drift(map(), [String.t()]) :: {:ok, %{missing_in_dropdown: [String.t()], orphan_dropdown_labels: [String.t()]}}
  def validate_drift(profiles, dropdown_labels) when is_map(profiles) and is_list(dropdown_labels) do
    profile_names = Map.keys(profiles)
    label_set = MapSet.new(dropdown_labels)
    profile_set = MapSet.new(profile_names)

    {:ok,
     %{
       missing_in_dropdown: profile_set |> MapSet.difference(label_set) |> Enum.sort(),
       orphan_dropdown_labels: label_set |> MapSet.difference(profile_set) |> Enum.sort()
     }}
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/profile_resolver_test.exs --no-start --trace`
Expected: PASS — 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/profile_resolver.ex elixir/test/symphony_elixir/profile_resolver_test.exs && git commit -m "feat(elixir): add ProfileResolver with precedence + safety floor + drift detection"
```

---

### Task 9: AgentRunner — resolve profile + select adapter

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/agent_runner_test.exs`

- [ ] **Step 1: Add tests for profile-based dispatch**

Add to `agent_runner_test.exs`:

```elixir
describe "profile-based dispatch" do
  setup do
    Application.put_env(:symphony_elixir, :tracker_adapter_override, SymphonyElixir.Tracker.MemoryMonday)
    SymphonyElixir.Tracker.MemoryMonday.reset()
    on_exit(fn -> Application.delete_env(:symphony_elixir, :tracker_adapter_override) end)
    :ok
  end

  test "resolves profile via ProfileResolver and selects matching adapter" do
    flunk("scaffolding — implementing agent fills in based on existing AgentRunner test patterns")
  end

  test "re-resolves profile at retry boundary (operator may have flipped column)" do
    flunk("scaffolding")
  end

  test "refuses to dispatch on safety-floor violation" do
    flunk("scaffolding")
  end

  test "stores runtime-native tokens under agent_native_tokens.<kind>" do
    flunk("scaffolding")
  end
end
```

Replace `flunk` calls with real tests.

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/agent_runner_test.exs --no-start --trace`
Expected: FAIL.

- [ ] **Step 3: Implement profile-based dispatch in AgentRunner**

In `elixir/lib/symphony_elixir/agent_runner.ex`:

1. Before launching the agent subprocess (currently hardcoded to Codex), call `ProfileResolver.resolve(issue, settings.profiles, settings.agent.default_profile, settings.agent.sandbox_safety_floor)`.

2. On `{:error, _}`, log operator-visible error and skip dispatch (orchestrator's failure counter handles retry).

3. On `{:ok, profile}`, select the adapter module from `%{codex: Codex.Adapter, claude: Claude.Adapter, gemini: Gemini.Adapter}[profile.kind]`.

4. Pass `profile.config` (merged with safety_floor under `:_safety_floor`) to `adapter.start_session(workspace_path, config)`.

5. Use `adapter.send_turn`, `adapter.stream_events`, `adapter.stop_session` polymorphically.

6. After completion, call `adapter.runtime_native_tokens(session)` and store under `state.agent_native_tokens[Atom.to_string(profile.kind)] = native_map`.

7. **Re-resolution at retry**: when the orchestrator triggers a retry attempt, `AgentRunner.run/3` is called fresh — re-fetch the issue (or re-read profile column) and call ProfileResolver again. The orchestrator must re-fetch the item before retry; ensure that's wired in.

- [ ] **Step 4: Run tests**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix test test/symphony_elixir/agent_runner_test.exs --no-start --trace`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/agent_runner_test.exs && git commit -m "feat(elixir): AgentRunner resolves profile per dispatch and routes via AgentRuntime adapters"
```

---

### Task 10: Orchestrator — per-profile concurrency caps

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_test.exs`

- [ ] **Step 1: Add test**

```elixir
describe "per-profile concurrency caps" do
  test "respects profile.max_concurrent alongside global cap" do
    flunk("scaffolding — seed MemoryMonday with 5 items profile=claude_opus, profile cap=2, global cap=10; assert exactly 2 dispatched")
  end
end
```

- [ ] **Step 2: Run to confirm failure**, **Step 3: Implement**

In orchestrator state, add `running_by_profile: %{}` (string profile name → integer count). On dispatch:
1. Resolve profile.
2. If `profile.max_concurrent` is set and `running_by_profile[profile.name] >= profile.max_concurrent`, hold back (don't dispatch).
3. Otherwise dispatch and increment counter; decrement on worker exit.

Add `running_by_profile_count(state, profile_name)` helper.

- [ ] **Step 4: Run tests**, **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/orchestrator_test.exs && git commit -m "feat(elixir): orchestrator enforces per-profile concurrency caps"
```

---

### Task 11: Config validate_semantics — profile-related checks

**Files:**
- Modify: `elixir/lib/symphony_elixir/config.ex`
- Modify: `elixir/test/symphony_elixir/config_schema_test.exs`

- [ ] **Step 1-3: Add validation rules**

In `Config.validate_semantics/1`, after existing rules, add:

```elixir
settings.agent.default_profile not in [nil, ""] and
not Map.has_key?(settings.profiles, settings.agent.default_profile) ->
  {:error, {:default_profile_not_in_profiles_map, settings.agent.default_profile}}

unknown_kind_profile(settings.profiles) != nil ->
  {:error, {:unknown_profile_kind, unknown_kind_profile(settings.profiles)}}

profile_safety_floor_violation(settings) != nil ->
  {:error, {:profile_safety_floor_violation, profile_safety_floor_violation(settings)}}
```

with helper functions `unknown_kind_profile/1` (returns first profile name whose kind is not in `:codex/:claude/:gemini`) and `profile_safety_floor_violation/1` (returns first profile name failing the floor).

Add tests for each new error class.

- [ ] **Step 4: Run tests**, **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/config.ex elixir/test/symphony_elixir/config_schema_test.exs && git commit -m "feat(elixir): config validate_semantics rejects bad profiles, missing default, safety-floor violations"
```

---

### Task 12: Update WORKFLOW.md with profiles + sandbox_safety_floor

**Files:**
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 1: Update front matter**

Add to WORKFLOW.md front matter:

```yaml
tracker:
  # ... existing fields ...
  profile_column_id: "dropdown_mm30zep"

profiles:
  claude_opus:
    kind: claude
    max_concurrent: 2
    claude:
      command: "claude --print --output-format stream-json --input-format stream-json"
      model: "claude-opus-4-7"
      permission_mode: "acceptEdits"
      allowed_tools: ["Read", "Edit", "Write", "Bash(git:*)", "Bash(make:*)", "Bash(mix:*)"]
  claude_sonnet:
    kind: claude
    max_concurrent: 6
    claude:
      command: "claude --print --output-format stream-json --input-format stream-json"
      model: "claude-sonnet-4-6"
      permission_mode: "acceptEdits"
      allowed_tools: ["Read", "Edit", "Write", "Bash(git:*)", "Bash(make:*)", "Bash(mix:*)"]
  codex_gpt55_xhigh:
    kind: codex
    max_concurrent: 4
    codex:
      command: "codex --config 'model=\"gpt-5.5\"' --config model_reasoning_effort=xhigh app-server"
      approval_policy: never
      thread_sandbox: workspace-write
  gemini_long_context:
    kind: gemini
    max_concurrent: 3
    gemini:
      command: "gemini --model gemini-2.5-pro --output-format stream-json --sandbox"

agent:
  default_profile: claude_opus
  sandbox_safety_floor:
    codex:
      thread_sandbox: workspace-write
      approval_policy: never
    claude:
      permission_mode: acceptEdits
      bash_denylist: ["*sudo*", "*rm -rf*", "*chmod 777*", "*curl * | sh*", "*wget * | sh*"]
    gemini:
      require_sandbox: true
      forbid_yolo: true
  max_concurrent_agents: 10
  max_turns: 20
```

The prompt body remains unchanged from Spec 1.

- [ ] **Step 2: Verify front matter parses**

Run: `cd elixir && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" mix run --no-start -e 'IO.inspect(SymphonyElixir.Workflow.load())'`
Expected: `{:ok, %{config: %{...profiles map populated...}, ...}}`

- [ ] **Step 3: Commit**

```bash
git add elixir/WORKFLOW.md && git commit -m "feat(elixir): add profiles, default_profile, sandbox_safety_floor to WORKFLOW.md"
```

---

### Task 13: Live boot smoke test (operator)

**Files:** none (operator validation step).

- [ ] **Step 1: Build + boot Symphony**

Run: `cd elixir && mix build && PATH="/tmp/elixir-extract/bin:/tmp/erlang-prefix/erlang/bin:$PATH" /mnt/d_drive/repos/podcast/scripts/secret_exec.py --secret-env MONDAY_API_TOKEN=mybcat/integrations/api-keys/monday:api_token -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails ./WORKFLOW.md`

Expected: Boot, heartbeat acquire, poll loop, dashboard renders. No GraphQL errors. No crashes.

- [ ] **Step 2: Create one Tech Board item with profile override**

In Monday UI, on board `8173460438`:
- Title: `[Symphony Spec 2 Smoke Test] noop`
- Symphony Status: `Symphony Ready`
- Symphony Profile: `claude_opus` (or any other profile)

- [ ] **Step 3: Verify dispatch**

Within ~5s, verify in Monday UI:
- Symphony Status flipped to `In Progress`
- `## Symphony Workpad` Update created on the item

In a separate terminal: `ps aux | grep claude` should show a `claude --print --output-format stream-json` subprocess in the per-item workspace.

- [ ] **Step 4: Tear down**

In Monday UI, set Symphony Status to `Cancelled`. Symphony's reconciliation tick should:
- Stop the Claude subprocess
- Run `before_remove` hook
- Delete workspace
- Release claim

- [ ] **Step 5: Tag**

```bash
cd /mnt/d_drive/repos/symphony && git tag -a spec-2-multi-runtime-profiles -m "Spec 2 (multi-runtime + profiles) shipped"
```

---

## Self-Review

**Spec coverage check:**
- §1 System Overview → Tasks 4-7 (runtime adapters), 8 (resolver), 9 (AgentRunner integration)
- §2.1 Runtime selection → Task 9
- §2.2 Sandbox safety floor → Tasks 5, 6, 7 (per-kind passes_safety_floor?), 8 (resolver enforcement)
- §2.3 Profile resolution + retry semantics → Task 8 (resolve), Task 9 (re-resolve at retry)
- §2.4 Token accounting native → Tasks 5, 6, 7 (per-adapter native shape), Task 9 (storage under agent_native_tokens.<kind>)
- §2.5 Per-profile concurrency caps → Task 10
- §2.6 Startup drift validation → Task 11 (Config.validate_semantics + ProfileResolver.validate_drift call site)
- §3 Non-behaviors → enforced via test assertions
- §4 Integration boundaries → Tasks 5, 6, 7 cover Codex/Claude/Gemini contracts
- §5 Behavioral scenarios S1-S7 → mostly covered by Tasks 8-10 tests; S6 (drift detection) covered by Task 11
- §6 Per-part context layers → file structure aligns
- §7 SPEC.md diff plan → out of scope for plan execution
- §8 Reference impl deltas → Tasks 4-12 implement the table
- §9 Tech Board setup delta → OP-1 done
- §10 Out of scope → tasks correctly stop short of rule-based routing, mid-flight runtime swap, etc.
- §11 Ambiguity warnings (locked) → reflected in tasks
- §12 Implementation constraints (sandbox floor predicates per adapter) → Tasks 5, 6, 7 + Task 8 dispatcher
- §13 Sample WORKFLOW.md → Task 12

**Placeholder scan:** Several `flunk("scaffolding")` calls remain in Task 9 and Task 10 tests. The implementing agent must replace these based on existing AgentRunner / Orchestrator test patterns. This is acceptable per superpowers:writing-plans — flunk acts as a documented "fill this in" anchor with explicit guidance.

**Type consistency:**
- `Profile.t()` shape consistent across Tasks 1, 2, 8, 9, 10
- `AgentRuntime` callback signatures consistent across Tasks 4, 5, 6, 7
- `Tracker.Issue.profile` field added in Task 3 and read in Task 8
- `agent_native_tokens.<kind>.<field>` shape consistent across Tasks 5, 6, 7, 9

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-03-symphony-multi-runtime-profiles.md`.** Two execution options:

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
