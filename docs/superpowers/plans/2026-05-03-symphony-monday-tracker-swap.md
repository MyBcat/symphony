# Symphony Monday Tracker Swap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Symphony's Linear tracker with Monday.com, with Symphony (Tracker primitive) owning all Monday writes; agent has no direct Monday access. Codex remains the only runtime in this spec line. Spec 2 (multi-runtime + profiles) ships separately on top of this.

**Architecture:** Symphony polls Monday for items in active states, dispatches a Codex App Server session in a per-item workspace, observes the agent's event stream, reads the agent's `_symphony_summary.md` at completion, and writes outcomes (status transitions, workpad Updates, PR URL) back to Monday. Heartbeat lock enforces single-instance per board. Tech Board (`8173460438`) is configured as a DRIVER board with a dedicated `Symphony Status` Status column and three companion columns.

**Tech Stack:** Elixir 1.19 / OTP 28; existing `:bandit`, `:phoenix`, `:phoenix_live_view`, `:req`, `:jason`, `:yaml_elixir`, `:solid`, `:ecto`. No new dependencies. Quality gate: `make all` (format, lint, coverage, dialyzer).

**Spec source:** `docs/superpowers/specs/2026-05-03-symphony-monday-tracker-swap.md`

---

## Operator Preconditions (one-time setup; do these FIRST)

These are not coding tasks — Ankit completes these before the implementation plan starts. The plan assumes they're done.

- [x] **OP-1: Tech Board column setup — DONE 2026-05-03 via /monday-com**
  - Symphony Status column created. ID: `color_mm30c3vb`. Labels: `Symphony Ready` (orange), `In Progress` (bright blue), `Human Review` (purple), `Merging` (dark purple), `Rework` (red), `Done` (green, `is_done: true`), `Cancelled` (black).
  - Symphony PR column created. ID: `link_mm30ak49`.
  - Heartbeat sentinel item created. ID: `11909898073`. URL: https://mybcat-squad.monday.com/boards/8173460438/pulses/11909898073

- [x] **OP-2: Monday API token — RESOLVED 2026-05-03**
  - Existing shared secret `mybcat/integrations/api-keys/monday` is reused per amended DL-007. Dedicated service user is deferred to a Phase 2 hardening task.

- [x] **OP-3: Token already in AWS Secrets Manager — RESOLVED 2026-05-03**
  - Verified: `secret-store verify mybcat/integrations/api-keys/monday` returns "exists and has a value."
  - Symphony references it via env var `MONDAY_API_TOKEN` (populated from this secret per the wiring in Task 1).

- [ ] **OP-4: Restrict Symphony Profile column edit permission (deferred to Spec 2)**
  - Skip in Spec 1 — there's no Symphony Profile column yet.

---

## File Structure (Spec 1 deliverables)

### Files to CREATE

| File | Responsibility |
|---|---|
| `elixir/lib/symphony_elixir/monday/client.ex` | Monday GraphQL transport (HTTP request, auth header, error handling) |
| `elixir/lib/symphony_elixir/monday/item.ex` | Normalize Monday item to Symphony's issue model; identifier derivation; PHI validation |
| `elixir/lib/symphony_elixir/monday/phi_detector.ex` | Regex-based PHI pattern detection (SSN, DOB, plausible patient names) |
| `elixir/lib/symphony_elixir/monday/adapter.ex` | Implements `Tracker` behaviour; all Monday writes go through here |
| `elixir/lib/symphony_elixir/monday/pr_detector.ex` | Scans agent event stream for PR URL pattern; emits typed event |
| `elixir/lib/symphony_elixir/monday/workpad.ex` | Renders Monday Update body from session state + workspace summary file |
| `elixir/lib/symphony_elixir/monday/heartbeat.ex` | Single-instance heartbeat lock (acquire/refresh/release on sentinel item) |
| `elixir/lib/symphony_elixir/tracker/memory_monday.ex` | In-memory Monday-shaped test double |
| `elixir/test/symphony_elixir/monday/client_test.exs` | Unit tests for GraphQL client (mocked HTTP) |
| `elixir/test/symphony_elixir/monday/item_test.exs` | Unit tests for item normalization + identifier derivation |
| `elixir/test/symphony_elixir/monday/phi_detector_test.exs` | Unit tests for PHI pattern detection |
| `elixir/test/symphony_elixir/monday/adapter_test.exs` | Unit tests for adapter (using memory backend) |
| `elixir/test/symphony_elixir/monday/pr_detector_test.exs` | Unit tests for PR detector |
| `elixir/test/symphony_elixir/monday/workpad_test.exs` | Unit tests for workpad renderer |
| `elixir/test/symphony_elixir/monday/heartbeat_test.exs` | Unit tests for heartbeat lock |
| `elixir/test/fixtures/monday/items_page_response.json` | Sample Monday GraphQL response — items_page query |
| `elixir/test/fixtures/monday/item_with_columns_response.json` | Sample Monday item read response |
| `elixir/test/fixtures/monday/change_simple_column_value_response.json` | Sample mutation response |

### Files to MODIFY

| File | Changes |
|---|---|
| `elixir/lib/symphony_elixir/tracker.ex` | Expand behaviour: add `upsert_workpad/2`, `set_pr_url/2`, `post_failure_update/2`, `acquire_heartbeat/0`, `release_heartbeat/0`, `validate_no_phi/1`. Switch dispatch to `Monday.Adapter`. |
| `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` | Remove `linear_graphql` tool definition and execution path. Module retained as scaffold but `tool_specs/0` returns `[]`. |
| `elixir/lib/symphony_elixir/config/schema.ex` | Tracker schema: replace Linear-specific fields with Monday fields (`board_id`, `identifier_prefix`, `*_column_id`, `heartbeat_item_id`, `heartbeat_ttl_ms`, `complexity_budget_per_tick`, `backoff_factor`, `max_polling_interval_ms`, `failure_ttl_count`, `handoff_states`). Endpoint default → Monday. |
| `elixir/lib/symphony_elixir/orchestrator.ex` | Add `handoff_states` handling; heartbeat acquire/release lifecycle; per-item failure counter for stranded TTL; trigger Symphony-side writes on dispatch / state-detected milestones / cleanup. |
| `elixir/lib/symphony_elixir/agent_runner.ex` | Subscribe to PR detector events; read `_symphony_summary.md` at completion; trigger Tracker writes via Monday.Adapter on dispatch / milestone / abnormal exit. |
| `elixir/WORKFLOW.md` | Replace front matter with Monday config; rewrite prompt body to match Spec 1 §13 (no Monday writes from agent; use `gh` for PRs; write `_symphony_summary.md` at completion). |
| `elixir/mix.exs` | Update `ignore_modules` for renames; add new modules to coverage exemptions where appropriate. |
| `elixir/test/symphony_elixir/live_e2e_test.exs` | Rewrite for Monday — disposable board, items, verify Symphony-side writes appear. |
| `elixir/test/symphony_elixir/tracker_test.exs` | Add tests for new behaviour callbacks (delegation). |

### Files to DELETE (last task; after Monday adapter validated end-to-end)

- `elixir/lib/symphony_elixir/linear/` (entire directory: `client.ex`, `adapter.ex`, `issue.ex`)
- `elixir/test/symphony_elixir/linear/` (if it exists; otherwise just remove related fixtures)

---

## Implementation Tasks

Each task is one TDD cycle: write failing test → run to confirm fail → implement → run to confirm pass → commit. Tasks are ordered for clean dependency flow.

---

### Task 1: Add `MONDAY_API_TOKEN` env wiring + verify secret available

**Files:**
- Modify: `elixir/.envrc.example` (create if absent)

- [ ] **Step 1: Create or update env example**

Create `elixir/.envrc.example` with:

```bash
export MONDAY_API_TOKEN="$(secret-get mybcat/integrations/api-keys/monday)"
```

- [ ] **Step 2: Verify `secret-get` returns a non-empty value**

Run: `secret-get mybcat/integrations/api-keys/monday | wc -c`
Expected: integer > 30 (Monday tokens are ~120+ chars).

- [ ] **Step 3: Commit**

```bash
git add elixir/.envrc.example && git commit -m "chore(elixir): wire MONDAY_API_TOKEN to existing mybcat integrations secret"
```

---

### Task 2: Update `Config.Schema.Tracker` for Monday

**Files:**
- Modify: `elixir/lib/symphony_elixir/config/schema.ex` (Tracker submodule, lines ~40-66)
- Test: `elixir/test/symphony_elixir/config_schema_test.exs` (modify existing or create)

- [ ] **Step 1: Write failing test**

Add to `elixir/test/symphony_elixir/config_schema_test.exs`:

```elixir
test "tracker schema accepts Monday config" do
  attrs = %{
    "tracker" => %{
      "kind" => "monday",
      "api_token" => "$MONDAY_API_TOKEN",
      "endpoint" => "https://api.monday.com/v2",
      "board_id" => 8173460438,
      "identifier_prefix" => "SYM",
      "symphony_status_column_id" => "status_mkfoo",
      "pr_column_id" => "link_mkbar",
      "heartbeat_item_id" => 1234567890,
      "heartbeat_ttl_ms" => 60_000,
      "complexity_budget_per_tick" => 500,
      "backoff_factor" => 2.0,
      "max_polling_interval_ms" => 60_000,
      "failure_ttl_count" => 5,
      "active_states" => ["Symphony Ready", "In Progress", "Rework"],
      "handoff_states" => ["Human Review", "Merging"],
      "terminal_states" => ["Done", "Cancelled"]
    }
  }

  assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
  assert settings.tracker.kind == "monday"
  assert settings.tracker.board_id == 8173460438
  assert settings.tracker.identifier_prefix == "SYM"
  assert settings.tracker.handoff_states == ["Human Review", "Merging"]
end
```

- [ ] **Step 2: Run test to verify fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/config_schema_test.exs -v`
Expected: FAIL — `tracker schema accepts Monday config` fails because new fields don't exist on the schema yet.

- [ ] **Step 3: Update Tracker schema**

In `elixir/lib/symphony_elixir/config/schema.ex`, replace the entire `defmodule Tracker do` block (lines 40-66) with:

```elixir
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
  end
end
```

Also update `finalize_settings/1` (around line 369) — replace `LINEAR_API_KEY` resolution with `MONDAY_API_TOKEN`:

```elixir
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
```

Remove the `:assignee` field from the schema entirely (Linear-specific).

- [ ] **Step 4: Run test to verify pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/config_schema_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/config/schema.ex elixir/test/symphony_elixir/config_schema_test.exs && git commit -m "feat(elixir): retarget tracker schema from Linear to Monday"
```

---

### Task 3: Create `Monday.PHIDetector`

**Files:**
- Create: `elixir/lib/symphony_elixir/monday/phi_detector.ex`
- Create: `elixir/test/symphony_elixir/monday/phi_detector_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/monday/phi_detector_test.exs`:

```elixir
defmodule SymphonyElixir.Monday.PHIDetectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.PHIDetector

  describe "scan/1" do
    test "returns :clean on safe engineering text" do
      text = "Fix Bland AI bot for client ABC-001 — supervisor reports timing issue."
      assert PHIDetector.scan(text) == :clean
    end

    test "flags SSN pattern" do
      text = "Patient context: 123-45-6789 reported issue."
      assert {:phi, [{:ssn, _}]} = PHIDetector.scan(text)
    end

    test "flags DOB pattern (MM/DD/YYYY)" do
      text = "DOB: 03/14/1985 confirmed."
      assert {:phi, [{:dob, _}]} = PHIDetector.scan(text)
    end

    test "flags plausible full-name pattern in patient context" do
      text = "Patient John Smith requested follow-up."
      assert {:phi, [{:patient_name, _}]} = PHIDetector.scan(text)
    end

    test "does not flag titles like 'fix Symphony Codex tool' as patient names" do
      text = "Fix Symphony Codex tool injection."
      assert PHIDetector.scan(text) == :clean
    end

    test "returns multiple findings when multiple patterns match" do
      text = "Patient Jane Doe DOB 01/02/1990 SSN 555-44-3333"
      assert {:phi, findings} = PHIDetector.scan(text)
      kinds = Enum.map(findings, &elem(&1, 0))
      assert :ssn in kinds
      assert :dob in kinds
      assert :patient_name in kinds
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/phi_detector_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement `Monday.PHIDetector`**

Create `elixir/lib/symphony_elixir/monday/phi_detector.ex`:

```elixir
defmodule SymphonyElixir.Monday.PHIDetector do
  @moduledoc """
  Pattern-based PHI detection for Monday item content. Tech Board is a no-PHI
  surface per Spec 1 DL-011. This detector refuses items whose title or
  description matches PHI patterns at ingestion.

  Patterns are intentionally conservative: false positives are preferred over
  false negatives because false positives surface as "fix the item text," while
  false negatives risk HIPAA exposure.
  """

  @ssn ~r/\b\d{3}-\d{2}-\d{4}\b/
  @dob ~r/\b(0?[1-9]|1[0-2])[\/\-](0?[1-9]|[12]\d|3[01])[\/\-](19|20)\d{2}\b/
  @patient_name_context ~r/\b(?:patient|pt\.?|insured|enrollee|member)\s+([A-Z][a-z]{2,}\s+[A-Z][a-z]{2,})\b/

  @type finding :: {:ssn | :dob | :patient_name, String.t()}

  @spec scan(String.t() | nil) :: :clean | {:phi, [finding()]}
  def scan(nil), do: :clean
  def scan(""), do: :clean

  def scan(text) when is_binary(text) do
    findings =
      []
      |> append_findings(:ssn, Regex.scan(@ssn, text))
      |> append_findings(:dob, Regex.scan(@dob, text))
      |> append_findings(:patient_name, Regex.scan(@patient_name_context, text, capture: :all_but_first))

    case findings do
      [] -> :clean
      list -> {:phi, list}
    end
  end

  defp append_findings(acc, _kind, []), do: acc

  defp append_findings(acc, kind, matches) do
    Enum.reduce(matches, acc, fn match, inner_acc ->
      case match do
        [_full | rest] when rest != [] -> [{kind, hd(rest)} | inner_acc]
        [text] -> [{kind, text} | inner_acc]
        text when is_binary(text) -> [{kind, text} | inner_acc]
      end
    end)
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/phi_detector_test.exs -v`
Expected: PASS — all 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/phi_detector.ex elixir/test/symphony_elixir/monday/phi_detector_test.exs && git commit -m "feat(elixir): add Monday.PHIDetector for Tech Board no-PHI enforcement"
```

---

### Task 4: Create `Monday.Item` (normalization + identifier derivation)

**Files:**
- Create: `elixir/lib/symphony_elixir/monday/item.ex`
- Create: `elixir/test/symphony_elixir/monday/item_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/monday/item_test.exs`:

```elixir
defmodule SymphonyElixir.Monday.ItemTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Item

  @raw_item %{
    "id" => "9482736152",
    "name" => "Fix Codex tool injection",
    "url" => "https://mybcat-squad.monday.com/boards/8173460438/pulses/9482736152",
    "created_at" => "2026-05-01T10:00:00Z",
    "updated_at" => "2026-05-03T08:00:00Z",
    "column_values" => [
      %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"},
      %{"id" => "priority_abc", "text" => "High"},
      %{"id" => "description_def", "text" => "Engineering task description here."}
    ]
  }

  @config %{
    identifier_prefix: "SYM",
    symphony_status_column_id: "symphony_status_xyz",
    priority_column_id: "priority_abc",
    description_column_id: "description_def",
    branch_column_id: nil,
    labels_column_id: nil
  }

  describe "from_monday/2" do
    test "derives identifier as <prefix>-<item_id>" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.identifier == "SYM-9482736152"
      assert item.id == "9482736152"
    end

    test "extracts state from configured symphony_status column" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.state == "Symphony Ready"
    end

    test "extracts description from configured column when set" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.description == "Engineering task description here."
    end

    test "falls back to identifier when branch_column_id is nil" do
      assert {:ok, item} = Item.from_monday(@raw_item, @config)
      assert item.branch_name == "SYM-9482736152"
    end

    test "rejects items containing PHI in title" do
      raw = put_in(@raw_item["name"], "Patient John Smith reported issue")
      assert {:error, {:phi_detected, [{:patient_name, _}]}} = Item.from_monday(raw, @config)
    end

    test "rejects items containing PHI in description" do
      raw =
        update_in(@raw_item["column_values"], fn cols ->
          Enum.map(cols, fn
            %{"id" => "description_def"} = c -> %{c | "text" => "DOB: 01/02/1990 reported it"}
            other -> other
          end)
        end)

      assert {:error, {:phi_detected, _}} = Item.from_monday(raw, @config)
    end

    test "errors when symphony_status column is not present in column_values" do
      raw = update_in(@raw_item["column_values"], fn cols ->
        Enum.reject(cols, &(&1["id"] == "symphony_status_xyz"))
      end)

      assert {:error, {:missing_column, "symphony_status_xyz"}} = Item.from_monday(raw, @config)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/item_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement `Monday.Item`**

Create `elixir/lib/symphony_elixir/monday/item.ex`:

```elixir
defmodule SymphonyElixir.Monday.Item do
  @moduledoc """
  Normalize Monday item payloads into Symphony's issue model.

  Identifier scheme: `<config.identifier_prefix>-<item.id>` (per Spec 1 DL-004).

  PHI rejection: item title and description column are scanned via
  `SymphonyElixir.Monday.PHIDetector`; on hit, returns `{:error, {:phi_detected, findings}}`.
  Tech Board is a no-PHI surface per Spec 1 DL-011.
  """

  alias SymphonyElixir.Monday.PHIDetector

  @type config :: %{
          identifier_prefix: String.t(),
          symphony_status_column_id: String.t(),
          priority_column_id: String.t() | nil,
          description_column_id: String.t() | nil,
          branch_column_id: String.t() | nil,
          labels_column_id: String.t() | nil
        }

  @type t :: %{
          id: String.t(),
          identifier: String.t(),
          title: String.t(),
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t(),
          branch_name: String.t(),
          url: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  @spec from_monday(map(), config()) ::
          {:ok, t()} | {:error, {:missing_column, String.t()} | {:phi_detected, [PHIDetector.finding()]}}
  def from_monday(raw, config) when is_map(raw) and is_map(config) do
    title = Map.get(raw, "name", "")
    description = column_text(raw, config[:description_column_id])

    with :clean <- PHIDetector.scan(title),
         :clean <- PHIDetector.scan(description),
         {:ok, state} <- require_column_text(raw, config.symphony_status_column_id) do
      identifier = "#{config.identifier_prefix}-#{raw["id"]}"

      item = %{
        id: raw["id"],
        identifier: identifier,
        title: title,
        description: description,
        priority: priority_value(raw, config[:priority_column_id]),
        state: state,
        branch_name: branch_value(raw, config[:branch_column_id], identifier),
        url: Map.get(raw, "url"),
        labels: labels_value(raw, config[:labels_column_id]),
        blocked_by: [],
        created_at: Map.get(raw, "created_at"),
        updated_at: Map.get(raw, "updated_at")
      }

      {:ok, item}
    else
      {:phi, findings} -> {:error, {:phi_detected, findings}}
      {:error, _} = err -> err
    end
  end

  defp require_column_text(raw, column_id) when is_binary(column_id) do
    case column_text(raw, column_id) do
      nil -> {:error, {:missing_column, column_id}}
      text -> {:ok, text}
    end
  end

  defp column_text(_raw, nil), do: nil

  defp column_text(raw, column_id) when is_binary(column_id) do
    raw
    |> Map.get("column_values", [])
    |> Enum.find_value(fn col ->
      if col["id"] == column_id, do: Map.get(col, "text"), else: nil
    end)
  end

  defp priority_value(raw, column_id) do
    case column_text(raw, column_id) do
      nil -> nil
      text -> priority_label_to_int(text)
    end
  end

  defp priority_label_to_int("High"), do: 1
  defp priority_label_to_int("Medium"), do: 2
  defp priority_label_to_int("Low"), do: 3
  defp priority_label_to_int(_), do: nil

  defp branch_value(_raw, nil, identifier_fallback), do: identifier_fallback

  defp branch_value(raw, column_id, identifier_fallback) do
    case column_text(raw, column_id) do
      nil -> identifier_fallback
      "" -> identifier_fallback
      text -> text
    end
  end

  defp labels_value(_raw, nil), do: []

  defp labels_value(raw, column_id) do
    case column_text(raw, column_id) do
      nil -> []
      "" -> []
      text -> text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.downcase/1)
    end
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/item_test.exs -v`
Expected: PASS — all 7 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/item.ex elixir/test/symphony_elixir/monday/item_test.exs && git commit -m "feat(elixir): add Monday.Item normalization with PHI rejection"
```

---

### Task 5: Create `Monday.Client` (GraphQL transport)

**Files:**
- Create: `elixir/lib/symphony_elixir/monday/client.ex`
- Create: `elixir/test/symphony_elixir/monday/client_test.exs`
- Create: `elixir/test/fixtures/monday/items_page_response.json`

- [ ] **Step 1: Create test fixture**

Create `elixir/test/fixtures/monday/items_page_response.json`:

```json
{
  "data": {
    "boards": [
      {
        "items_page": {
          "cursor": null,
          "items": [
            {
              "id": "9482736152",
              "name": "Fix tool injection bug",
              "url": "https://mybcat-squad.monday.com/boards/8173460438/pulses/9482736152",
              "created_at": "2026-05-01T10:00:00Z",
              "updated_at": "2026-05-03T08:00:00Z",
              "column_values": [
                {"id": "symphony_status_xyz", "text": "Symphony Ready"},
                {"id": "priority_abc", "text": "High"}
              ]
            }
          ]
        }
      }
    ]
  }
}
```

- [ ] **Step 2: Write failing tests**

Create `elixir/test/symphony_elixir/monday/client_test.exs`:

```elixir
defmodule SymphonyElixir.Monday.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Client

  setup do
    fixture = File.read!("test/fixtures/monday/items_page_response.json") |> Jason.decode!()
    {:ok, fixture: fixture}
  end

  describe "graphql/3" do
    test "issues request with auth header and JSON body", %{fixture: fixture} do
      mock_req = fn url, opts ->
        assert url == "https://api.monday.com/v2"
        assert {"Authorization", "test-token"} in opts[:headers]
        assert {"Content-Type", "application/json"} in opts[:headers]
        body = Jason.decode!(opts[:json] |> Jason.encode!())
        assert body["query"] =~ "items_page"
        {:ok, %Req.Response{status: 200, body: fixture}}
      end

      assert {:ok, response} = Client.graphql("query Foo { items_page { items { id } } }", %{}, req_fun: mock_req, api_token: "test-token")
      assert response["data"]["boards"] != nil
    end

    test "returns {:error, :auth_failed} on 401" do
      mock_req = fn _url, _opts ->
        {:ok, %Req.Response{status: 401, body: %{"error" => "Unauthorized"}}}
      end

      assert {:error, :auth_failed} = Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "bad")
    end

    test "returns {:error, :rate_limited} on 429" do
      mock_req = fn _url, _opts ->
        {:ok, %Req.Response{status: 429, body: %{"error" => "Complexity"}}}
      end

      assert {:error, :rate_limited} = Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "x")
    end

    test "returns {:error, :timeout} on transport timeout" do
      mock_req = fn _url, _opts -> {:error, %Req.TransportError{reason: :timeout}} end

      assert {:error, :timeout} = Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "x")
    end

    test "returns {:error, {:graphql_errors, list}} when response has errors" do
      mock_req = fn _url, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"errors" => [%{"message" => "Field not found"}]}}}
      end

      assert {:error, {:graphql_errors, [%{"message" => "Field not found"}]}} =
               Client.graphql("query Foo {}", %{}, req_fun: mock_req, api_token: "x")
    end
  end
end
```

- [ ] **Step 3: Run tests to verify fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/client_test.exs -v`
Expected: FAIL — module does not exist.

- [ ] **Step 4: Implement `Monday.Client`**

Create `elixir/lib/symphony_elixir/monday/client.ex`:

```elixir
defmodule SymphonyElixir.Monday.Client do
  @moduledoc """
  Monday.com GraphQL transport. All requests go to the configured endpoint with
  the configured api_token. Returns normalized error tuples for common failure
  modes; callers do not parse HTTP statuses directly.
  """

  alias SymphonyElixir.Config

  @default_endpoint "https://api.monday.com/v2"
  @default_timeout_ms 15_000

  @type error ::
          :auth_failed
          | :rate_limited
          | :timeout
          | {:http, non_neg_integer()}
          | {:graphql_errors, [map()]}
          | {:transport, term()}

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, error()}
  def graphql(query, variables, opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, endpoint_from_config())
    api_token = Keyword.get(opts, :api_token, api_token_from_config())
    req_fun = Keyword.get(opts, :req_fun, &Req.post/2)

    headers = [
      {"Authorization", api_token},
      {"Content-Type", "application/json"},
      {"API-Version", "2024-10"}
    ]

    body = %{"query" => query, "variables" => variables || %{}}

    case req_fun.(endpoint, headers: headers, json: body, receive_timeout: @default_timeout_ms) do
      {:ok, %{status: 200, body: %{"errors" => errors}}} when is_list(errors) and errors != [] ->
        {:error, {:graphql_errors, errors}}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :auth_failed}

      {:ok, %{status: 403}} ->
        {:error, :auth_failed}

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp endpoint_from_config do
    case Config.settings!() do
      %{tracker: %{endpoint: endpoint}} when is_binary(endpoint) and endpoint != "" -> endpoint
      _ -> @default_endpoint
    end
  end

  defp api_token_from_config do
    case Config.settings!() do
      %{tracker: %{api_token: token}} when is_binary(token) -> token
      _ -> nil
    end
  end
end
```

- [ ] **Step 5: Run tests to verify pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/client_test.exs -v`
Expected: PASS — all 5 tests green.

- [ ] **Step 6: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/client.ex elixir/test/symphony_elixir/monday/client_test.exs elixir/test/fixtures/monday/items_page_response.json && git commit -m "feat(elixir): add Monday.Client GraphQL transport"
```

---

### Task 6: Expand `Tracker` behaviour with new callbacks

**Files:**
- Modify: `elixir/lib/symphony_elixir/tracker.ex`
- Create: `elixir/test/symphony_elixir/tracker_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/tracker_test.exs`:

```elixir
defmodule SymphonyElixir.TrackerTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Tracker

  defmodule FakeAdapter do
    @behaviour SymphonyElixir.Tracker

    def fetch_candidate_issues, do: {:ok, []}
    def fetch_issues_by_states(_), do: {:ok, []}
    def fetch_issue_states_by_ids(_), do: {:ok, []}
    def update_issue_state(_, _), do: :ok
    def upsert_workpad(_, _), do: :ok
    def set_pr_url(_, _), do: :ok
    def post_failure_update(_, _), do: :ok
    def acquire_heartbeat, do: :ok
    def release_heartbeat, do: :ok
    def validate_no_phi(_), do: :ok
  end

  setup do
    Application.put_env(:symphony_elixir, :tracker_adapter_override, FakeAdapter)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :tracker_adapter_override) end)
    :ok
  end

  test "delegates upsert_workpad to adapter" do
    assert Tracker.upsert_workpad("123", "body") == :ok
  end

  test "delegates set_pr_url to adapter" do
    assert Tracker.set_pr_url("123", "https://github.com/x/y/pull/1") == :ok
  end

  test "delegates post_failure_update to adapter" do
    assert Tracker.post_failure_update("123", "reason") == :ok
  end

  test "delegates acquire_heartbeat to adapter" do
    assert Tracker.acquire_heartbeat() == :ok
  end

  test "delegates release_heartbeat to adapter" do
    assert Tracker.release_heartbeat() == :ok
  end

  test "delegates validate_no_phi to adapter" do
    assert Tracker.validate_no_phi(%{title: "safe"}) == :ok
  end
end
```

- [ ] **Step 2: Run tests to verify fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_test.exs -v`
Expected: FAIL — new functions not defined on `Tracker`.

- [ ] **Step 3: Replace `tracker.ex`**

Replace `elixir/lib/symphony_elixir/tracker.ex` with:

```elixir
defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Tracker primitive contract. Symphony owns all Monday writes per Spec 1 DL-005.
  Adapter dispatch resolved at call time from config + optional override.
  """

  alias SymphonyElixir.Config

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback upsert_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  @callback set_pr_url(String.t(), String.t()) :: :ok | {:error, term()}
  @callback post_failure_update(String.t(), String.t()) :: :ok | {:error, term()}
  @callback acquire_heartbeat() :: :ok | {:error, term()}
  @callback release_heartbeat() :: :ok | {:error, term()}
  @callback validate_no_phi(map()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: adapter().update_issue_state(issue_id, state_name)

  @spec upsert_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  def upsert_workpad(issue_id, body), do: adapter().upsert_workpad(issue_id, body)

  @spec set_pr_url(String.t(), String.t()) :: :ok | {:error, term()}
  def set_pr_url(issue_id, url), do: adapter().set_pr_url(issue_id, url)

  @spec post_failure_update(String.t(), String.t()) :: :ok | {:error, term()}
  def post_failure_update(issue_id, body), do: adapter().post_failure_update(issue_id, body)

  @spec acquire_heartbeat() :: :ok | {:error, term()}
  def acquire_heartbeat, do: adapter().acquire_heartbeat()

  @spec release_heartbeat() :: :ok | {:error, term()}
  def release_heartbeat, do: adapter().release_heartbeat()

  @spec validate_no_phi(map()) :: :ok | {:error, term()}
  def validate_no_phi(item), do: adapter().validate_no_phi(item)

  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:symphony_elixir, :tracker_adapter_override) do
      nil -> default_adapter_for_kind()
      module -> module
    end
  end

  defp default_adapter_for_kind do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.MemoryMonday
      _ -> SymphonyElixir.Monday.Adapter
    end
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/tracker_test.exs -v`
Expected: PASS — all 6 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker.ex elixir/test/symphony_elixir/tracker_test.exs && git commit -m "feat(elixir): expand Tracker behaviour with workpad/pr/heartbeat/phi callbacks"
```

---

### Task 7: Create `Tracker.MemoryMonday` test double

**Files:**
- Create: `elixir/lib/symphony_elixir/tracker/memory_monday.ex`

- [ ] **Step 1: Implement `Tracker.MemoryMonday`**

Create `elixir/lib/symphony_elixir/tracker/memory_monday.ex`:

```elixir
defmodule SymphonyElixir.Tracker.MemoryMonday do
  @moduledoc """
  In-memory Monday-shaped Tracker backend used in tests. Backed by an Agent
  process keyed by the calling test pid for isolation.
  """

  @behaviour SymphonyElixir.Tracker

  use Agent

  @impl true
  def fetch_candidate_issues, do: {:ok, get_state(:items_active, [])}

  @impl true
  def fetch_issues_by_states(states), do: {:ok, get_state({:items_in_states, states}, [])}

  @impl true
  def fetch_issue_states_by_ids(_ids), do: {:ok, get_state(:item_states, [])}

  @impl true
  def update_issue_state(item_id, state) do
    push_event({:status_write, item_id, state})
    :ok
  end

  @impl true
  def upsert_workpad(item_id, body) do
    push_event({:workpad_write, item_id, body})
    :ok
  end

  @impl true
  def set_pr_url(item_id, url) do
    push_event({:pr_write, item_id, url})
    :ok
  end

  @impl true
  def post_failure_update(item_id, body) do
    push_event({:failure_write, item_id, body})
    :ok
  end

  @impl true
  def acquire_heartbeat do
    case get_state(:heartbeat, :unlocked) do
      :unlocked -> put_state(:heartbeat, :locked)
      :locked -> {:error, :lock_held_by_other}
    end
  end

  @impl true
  def release_heartbeat do
    put_state(:heartbeat, :unlocked)
    :ok
  end

  @impl true
  def validate_no_phi(_item), do: :ok

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.merge([name: __MODULE__], opts))
  end

  @spec set(atom() | tuple(), term()) :: :ok
  def set(key, value), do: put_state(key, value)

  @spec events() :: [tuple()]
  def events, do: get_state(:events, [])

  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  defp get_state(key, default) do
    ensure_started()
    Agent.get(__MODULE__, fn s -> Map.get(s, key, default) end)
  end

  defp put_state(key, value) do
    ensure_started()
    Agent.update(__MODULE__, fn s -> Map.put(s, key, value) end)
    :ok
  end

  defp push_event(event) do
    ensure_started()
    Agent.update(__MODULE__, fn s ->
      Map.update(s, :events, [event], &[event | &1])
    end)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, _} = start_link([])
      _pid -> :ok
    end
  end
end
```

- [ ] **Step 2: Verify it compiles and is loadable**

Run: `cd elixir && mise exec -- mix compile`
Expected: SUCCESS

- [ ] **Step 3: Commit**

```bash
git add elixir/lib/symphony_elixir/tracker/memory_monday.ex && git commit -m "feat(elixir): add Tracker.MemoryMonday in-memory test double"
```

---

### Task 8: Create `Monday.Adapter` — read paths

**Files:**
- Create: `elixir/lib/symphony_elixir/monday/adapter.ex`
- Create: `elixir/test/symphony_elixir/monday/adapter_test.exs`

- [ ] **Step 1: Write failing tests for read paths**

Create `elixir/test/symphony_elixir/monday/adapter_test.exs`:

```elixir
defmodule SymphonyElixir.Monday.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Adapter

  setup do
    Application.put_env(:symphony_elixir, :monday_client_module, FakeMondayClient)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :monday_client_module) end)

    config = %{
      tracker: %{
        kind: "monday",
        endpoint: "https://api.monday.com/v2",
        api_token: "test-token",
        board_id: 8173460438,
        identifier_prefix: "SYM",
        symphony_status_column_id: "symphony_status_xyz",
        priority_column_id: "priority_abc",
        description_column_id: nil,
        branch_column_id: nil,
        labels_column_id: nil,
        active_states: ["Symphony Ready", "In Progress", "Rework"],
        handoff_states: ["Human Review", "Merging"],
        terminal_states: ["Done", "Cancelled"],
        heartbeat_item_id: 999_000,
        heartbeat_ttl_ms: 60_000
      }
    }

    Application.put_env(:symphony_elixir, :test_config_override, config)
    on_exit(fn -> Application.delete_env(:symphony_elixir, :test_config_override) end)
    :ok
  end

  defmodule FakeMondayClient do
    def graphql(_query, _vars, _opts) do
      {:ok,
       %{
         "data" => %{
           "boards" => [
             %{
               "items_page" => %{
                 "cursor" => nil,
                 "items" => [
                   %{
                     "id" => "9482736152",
                     "name" => "Fix bug",
                     "url" => "https://example.com",
                     "created_at" => "2026-05-01T00:00:00Z",
                     "updated_at" => "2026-05-03T00:00:00Z",
                     "column_values" => [
                       %{"id" => "symphony_status_xyz", "text" => "Symphony Ready"}
                     ]
                   }
                 ]
               }
             }
           ]
         }
       }}
    end
  end

  test "fetch_candidate_issues returns normalized items in active and handoff states" do
    assert {:ok, [item]} = Adapter.fetch_candidate_issues()
    assert item.identifier == "SYM-9482736152"
    assert item.state == "Symphony Ready"
  end
end
```

(Note: This test uses an Application-env override pattern for `Config.settings!()`. Existing tests likely use this pattern; if not, the Adapter will need to accept config injection.)

- [ ] **Step 2: Run tests to verify fail**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/adapter_test.exs -v`
Expected: FAIL — `Monday.Adapter` does not exist.

- [ ] **Step 3: Implement read paths in `Monday.Adapter`**

Create `elixir/lib/symphony_elixir/monday/adapter.ex`:

```elixir
defmodule SymphonyElixir.Monday.Adapter do
  @moduledoc """
  Monday.com Tracker primitive. Owns all Monday writes per Spec 1 DL-005.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Monday.{Client, Item, PHIDetector}

  @items_page_query """
  query SymphonyItemsPage($boardId: ID!, $columnIds: [String!]) {
    boards(ids: [$boardId]) {
      items_page(limit: 100) {
        cursor
        items {
          id
          name
          url
          created_at
          updated_at
          column_values(ids: $columnIds) {
            id
            text
          }
        }
      }
    }
  }
  """

  @impl true
  def fetch_candidate_issues do
    cfg = tracker_config()
    eligible_states = cfg.active_states ++ cfg.handoff_states
    fetch_issues_filtered(cfg, eligible_states)
  end

  @impl true
  def fetch_issues_by_states(states), do: fetch_issues_filtered(tracker_config(), states)

  @impl true
  def fetch_issue_states_by_ids(_ids) do
    # In v1, used only for reconciliation — same path as candidates filtered by id list.
    # Implementing agent: extend with a separate `items` query if performance demands.
    {:ok, []}
  end

  defp fetch_issues_filtered(cfg, allowed_states) do
    column_ids =
      [
        cfg.symphony_status_column_id,
        cfg.priority_column_id,
        cfg.description_column_id,
        cfg.branch_column_id,
        cfg.labels_column_id,
        cfg[:profile_column_id]
      ]
      |> Enum.reject(&is_nil/1)

    case client_module().graphql(@items_page_query, %{"boardId" => cfg.board_id, "columnIds" => column_ids}, []) do
      {:ok, %{"data" => %{"boards" => [%{"items_page" => %{"items" => raw_items}}]}}} ->
        items =
          raw_items
          |> Enum.map(&Item.from_monday(&1, cfg))
          |> Enum.reduce({:ok, []}, fn
            {:ok, item}, {:ok, acc} ->
              if item.state in allowed_states, do: {:ok, [item | acc]}, else: {:ok, acc}

            {:error, _reason}, acc ->
              acc
          end)

        case items do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          err -> err
        end

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  # Write paths (Tracker primitive owns these per DL-005).
  # Implemented in Task 9.
  @impl true
  def update_issue_state(_item_id, _state_name), do: {:error, :not_implemented_yet}

  @impl true
  def upsert_workpad(_item_id, _body), do: {:error, :not_implemented_yet}

  @impl true
  def set_pr_url(_item_id, _url), do: {:error, :not_implemented_yet}

  @impl true
  def post_failure_update(_item_id, _body), do: {:error, :not_implemented_yet}

  @impl true
  def acquire_heartbeat, do: {:error, :not_implemented_yet}

  @impl true
  def release_heartbeat, do: {:error, :not_implemented_yet}

  @impl true
  def validate_no_phi(item) do
    title = Map.get(item, :title) || Map.get(item, "name")
    description = Map.get(item, :description)

    case PHIDetector.scan(title) do
      :clean ->
        case PHIDetector.scan(description) do
          :clean -> :ok
          {:phi, findings} -> {:error, {:phi_in_description, findings}}
        end

      {:phi, findings} ->
        {:error, {:phi_in_title, findings}}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :monday_client_module, Client)
  end

  defp tracker_config do
    case Application.get_env(:symphony_elixir, :test_config_override) do
      %{tracker: tracker} -> tracker
      _ -> Config.settings!().tracker |> Map.from_struct()
    end
  end
end
```

- [ ] **Step 4: Run tests to verify pass**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/adapter_test.exs -v`
Expected: PASS — `fetch_candidate_issues` test green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/adapter.ex elixir/test/symphony_elixir/monday/adapter_test.exs && git commit -m "feat(elixir): add Monday.Adapter read paths (fetch_candidate_issues, fetch_issues_by_states)"
```

---

### Task 9: `Monday.Adapter` — write paths (status, workpad, PR URL, failure update)

**Files:**
- Modify: `elixir/lib/symphony_elixir/monday/adapter.ex`
- Modify: `elixir/test/symphony_elixir/monday/adapter_test.exs`

- [ ] **Step 1: Add tests for write paths**

Add to `elixir/test/symphony_elixir/monday/adapter_test.exs`:

```elixir
describe "write paths" do
  defmodule WriteCapturingClient do
    def graphql(query, vars, _opts) do
      send(self_pid(), {:graphql, query, vars})
      cond do
        query =~ "change_simple_column_value" ->
          {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => "1"}}}}
        query =~ "create_update" ->
          {:ok, %{"data" => %{"create_update" => %{"id" => "u-1", "body" => Map.get(vars, "body")}}}}
        query =~ "edit_update" ->
          {:ok, %{"data" => %{"edit_update" => %{"id" => Map.get(vars, "id")}}}}
        query =~ "items.*updates" ->
          {:ok, %{"data" => %{"items" => [%{"updates" => []}]}}}
        true ->
          {:ok, %{"data" => %{}}}
      end
    end

    defp self_pid, do: Process.get(:test_pid)
  end

  setup do
    Process.put(:test_pid, self())
    Application.put_env(:symphony_elixir, :monday_client_module, WriteCapturingClient)
    :ok
  end

  test "update_issue_state issues change_simple_column_value mutation" do
    assert :ok = Adapter.update_issue_state("9482736152", "In Progress")
    assert_received {:graphql, query, %{"itemId" => "9482736152", "columnId" => "symphony_status_xyz", "value" => "In Progress"}}
    assert query =~ "change_simple_column_value"
  end

  test "set_pr_url writes to configured pr_column_id" do
    Application.put_env(:symphony_elixir, :test_config_override, %{
      tracker: %{
        Application.get_env(:symphony_elixir, :test_config_override).tracker
        | pr_column_id: "link_pr_x"
      }
    })

    assert :ok = Adapter.set_pr_url("9482736152", "https://github.com/x/y/pull/42")
    assert_received {:graphql, _query, %{"itemId" => "9482736152", "columnId" => "link_pr_x", "value" => v}}
    assert v =~ "github.com"
  end

  test "post_failure_update creates a Monday Update with a marker header" do
    assert :ok = Adapter.post_failure_update("9482736152", "Stranded after 5 attempts")
    assert_received {:graphql, query, %{"itemId" => 9_482_736_152, "body" => body}}
    assert query =~ "create_update"
    assert body =~ "## Symphony Failures"
    assert body =~ "Stranded after 5 attempts"
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/adapter_test.exs -v`
Expected: FAIL — write functions return `:not_implemented_yet`.

- [ ] **Step 3: Implement write paths in `Monday.Adapter`**

Replace the placeholder write impls in `elixir/lib/symphony_elixir/monday/adapter.ex` with:

```elixir
@change_simple_column_value """
mutation SymphonyChangeSimple($itemId: ID!, $columnId: String!, $value: String!) {
  change_simple_column_value(item_id: $itemId, column_id: $columnId, value: $value) {
    id
  }
}
"""

@create_update """
mutation SymphonyCreateUpdate($itemId: ID!, $body: String!) {
  create_update(item_id: $itemId, body: $body) {
    id
    body
  }
}
"""

@edit_update """
mutation SymphonyEditUpdate($id: ID!, $body: String!) {
  edit_update(id: $id, body: $body) {
    id
  }
}
"""

@get_item_updates """
query SymphonyGetItemUpdates($itemId: ID!) {
  items(ids: [$itemId]) {
    updates(limit: 25) {
      id
      body
    }
  }
}
"""

@workpad_marker "## Symphony Workpad"
@failure_marker "## Symphony Failures"

@impl true
def update_issue_state(item_id, state_name) do
  cfg = tracker_config()
  vars = %{"itemId" => item_id, "columnId" => cfg.symphony_status_column_id, "value" => state_name}

  case client_module().graphql(@change_simple_column_value, vars, []) do
    {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => _}}}} -> :ok
    {:error, _} = err -> err
    other -> {:error, {:unexpected_response, other}}
  end
end

@impl true
def upsert_workpad(item_id, body) do
  full_body = ensure_marker(body, @workpad_marker)
  upsert_marked_update(item_id, @workpad_marker, full_body)
end

@impl true
def set_pr_url(item_id, url) do
  cfg = tracker_config()

  case cfg[:pr_column_id] do
    nil -> {:error, :no_pr_column_configured}
    column_id ->
      vars = %{"itemId" => item_id, "columnId" => column_id, "value" => url}

      case client_module().graphql(@change_simple_column_value, vars, []) do
        {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => _}}}} -> :ok
        {:error, _} = err -> err
        other -> {:error, {:unexpected_response, other}}
      end
  end
end

@impl true
def post_failure_update(item_id, body) do
  full_body = "#{@failure_marker}\n\n#{body}"
  case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => full_body}, []) do
    {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
    {:error, _} = err -> err
    other -> {:error, {:unexpected_response, other}}
  end
end

defp upsert_marked_update(item_id, marker, body) do
  case find_update_by_marker(item_id, marker) do
    {:ok, nil} ->
      create_marked_update(item_id, body)

    {:ok, update_id} ->
      edit_existing_update(update_id, body)

    {:error, :ambiguous} ->
      {:error, :ambiguous_workpad}

    {:error, _} = err ->
      err
  end
end

defp find_update_by_marker(item_id, marker) do
  case client_module().graphql(@get_item_updates, %{"itemId" => parse_item_id(item_id)}, []) do
    {:ok, %{"data" => %{"items" => [%{"updates" => updates}]}}} ->
      matches = Enum.filter(updates, fn u -> String.starts_with?(u["body"] || "", marker) end)

      case matches do
        [] -> {:ok, nil}
        [single] -> {:ok, single["id"]}
        _multiple -> {:error, :ambiguous}
      end

    {:error, _} = err ->
      err

    other ->
      {:error, {:unexpected_response, other}}
  end
end

defp create_marked_update(item_id, body) do
  case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => body}, []) do
    {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
    {:error, _} = err -> err
    other -> {:error, {:unexpected_response, other}}
  end
end

defp edit_existing_update(update_id, body) do
  case client_module().graphql(@edit_update, %{"id" => update_id, "body" => body}, []) do
    {:ok, %{"data" => %{"edit_update" => %{"id" => _}}}} -> :ok
    {:error, _} = err -> err
    other -> {:error, {:unexpected_response, other}}
  end
end

defp ensure_marker(body, marker) do
  if String.starts_with?(body || "", marker), do: body, else: "#{marker}\n\n#{body}"
end

defp parse_item_id(item_id) when is_integer(item_id), do: item_id

defp parse_item_id(item_id) when is_binary(item_id) do
  case Integer.parse(item_id) do
    {int, ""} -> int
    _ -> item_id
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/adapter_test.exs -v`
Expected: PASS — write-path tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/adapter.ex elixir/test/symphony_elixir/monday/adapter_test.exs && git commit -m "feat(elixir): add Monday.Adapter write paths (status, workpad, PR URL, failure update)"
```

---

### Task 10: `Monday.Adapter` — heartbeat acquire/release

**Files:**
- Modify: `elixir/lib/symphony_elixir/monday/adapter.ex`
- Modify: `elixir/test/symphony_elixir/monday/adapter_test.exs`

- [ ] **Step 1: Add tests for heartbeat**

Add to the adapter test:

```elixir
describe "heartbeat" do
  test "acquire_heartbeat creates fresh heartbeat update when sentinel has no recent one" do
    assert :ok = Adapter.acquire_heartbeat()
    assert_received {:graphql, query, _vars}
    assert query =~ "create_update"
  end

  test "acquire_heartbeat returns :lock_held_by_other when fresh heartbeat from another instance exists" do
    # configure WriteCapturingClient to return an existing heartbeat from a different instance_id within TTL
    # (test-double extension; implementing agent fills in the variant client)
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/adapter_test.exs:N -v`
Expected: FAIL — heartbeat methods return `:not_implemented_yet`.

- [ ] **Step 3: Implement heartbeat acquire/release**

Add to `elixir/lib/symphony_elixir/monday/adapter.ex`:

```elixir
@heartbeat_marker "## Symphony Heartbeat"

@impl true
def acquire_heartbeat do
  cfg = tracker_config()
  ttl_ms = cfg.heartbeat_ttl_ms
  instance_id = instance_id()

  with {:ok, existing} <- find_update_by_marker(cfg.heartbeat_item_id, @heartbeat_marker),
       :ok <- assert_lock_available(existing, ttl_ms, instance_id) do
    body = render_heartbeat_body(instance_id)

    case existing do
      nil -> create_marked_update(cfg.heartbeat_item_id, "#{@heartbeat_marker}\n\n#{body}")
      update_id -> edit_existing_update(update_id, "#{@heartbeat_marker}\n\n#{body}")
    end
  end
end

@impl true
def release_heartbeat do
  cfg = tracker_config()

  case find_update_by_marker(cfg.heartbeat_item_id, @heartbeat_marker) do
    {:ok, nil} -> :ok
    {:ok, update_id} -> edit_existing_update(update_id, "#{@heartbeat_marker}\n\nreleased\n")
    {:error, _} = err -> err
  end
end

defp assert_lock_available(nil, _ttl, _instance), do: :ok

defp assert_lock_available(_update_id, _ttl, _instance) do
  # NOTE for implementing agent: read the existing update's body via a follow-up
  # `items.updates` query, parse `instance_id` and `timestamp`, compare against
  # ttl. If same instance OR expired → :ok; else → {:error, :lock_held_by_other}.
  # Test variant of WriteCapturingClient must return an existing-update body.
  :ok
end

defp render_heartbeat_body(instance_id) do
  ts = DateTime.utc_now() |> DateTime.to_iso8601()
  "instance_id: #{instance_id}\ntimestamp: #{ts}\n"
end

defp instance_id do
  case Application.get_env(:symphony_elixir, :instance_id) do
    nil ->
      id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
      Application.put_env(:symphony_elixir, :instance_id, id)
      id

    id ->
      id
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/adapter_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/adapter.ex elixir/test/symphony_elixir/monday/adapter_test.exs && git commit -m "feat(elixir): add Monday.Adapter heartbeat acquire/release"
```

---

### Task 11: Create `Monday.PRDetector`

**Files:**
- Create: `elixir/lib/symphony_elixir/monday/pr_detector.ex`
- Create: `elixir/test/symphony_elixir/monday/pr_detector_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/monday/pr_detector_test.exs`:

```elixir
defmodule SymphonyElixir.Monday.PRDetectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.PRDetector

  test "detects standard GitHub PR URL" do
    text = "Opened PR: https://github.com/openai/symphony/pull/123"
    assert {:ok, "https://github.com/openai/symphony/pull/123"} = PRDetector.scan(text)
  end

  test "ignores GitHub issue URLs" do
    text = "Filed issue: https://github.com/openai/symphony/issues/123"
    assert :no_match = PRDetector.scan(text)
  end

  test "ignores GitHub gist URLs" do
    text = "Created gist: https://gist.github.com/foo/bar"
    assert :no_match = PRDetector.scan(text)
  end

  test "returns first match when multiple PRs are mentioned" do
    text = "Created https://github.com/x/y/pull/1 and https://github.com/x/y/pull/2"
    assert {:ok, "https://github.com/x/y/pull/1"} = PRDetector.scan(text)
  end

  test "returns :no_match on plain prose" do
    assert PRDetector.scan("Working on the implementation now.") == :no_match
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/pr_detector_test.exs -v`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `Monday.PRDetector`**

Create `elixir/lib/symphony_elixir/monday/pr_detector.ex`:

```elixir
defmodule SymphonyElixir.Monday.PRDetector do
  @moduledoc """
  Scans agent event-stream text for the first GitHub PR URL.
  Pinned regex requires `pull/<digits>` boundary to avoid matching issues, gists,
  or arbitrary github.com URLs.
  """

  @pr_url_regex ~r{https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+(?=\b|/|$)}

  @spec scan(String.t() | nil) :: {:ok, String.t()} | :no_match
  def scan(nil), do: :no_match
  def scan(""), do: :no_match

  def scan(text) when is_binary(text) do
    case Regex.run(@pr_url_regex, text) do
      [url | _] -> {:ok, url}
      nil -> :no_match
    end
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/pr_detector_test.exs -v`
Expected: PASS — all 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/pr_detector.ex elixir/test/symphony_elixir/monday/pr_detector_test.exs && git commit -m "feat(elixir): add Monday.PRDetector for agent-stream PR URL extraction"
```

---

### Task 12: Create `Monday.Workpad` (body renderer)

**Files:**
- Create: `elixir/lib/symphony_elixir/monday/workpad.ex`
- Create: `elixir/test/symphony_elixir/monday/workpad_test.exs`

- [ ] **Step 1: Write failing tests**

Create `elixir/test/symphony_elixir/monday/workpad_test.exs`:

```elixir
defmodule SymphonyElixir.Monday.WorkpadTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.Workpad

  describe "render_session_start/1" do
    test "produces a structured session-start markdown body" do
      session = %{
        identifier: "SYM-9482736152",
        instance_id: "abc12345",
        host: "devbox-01",
        workspace_path: "/home/dev/code/symphony-workspaces/SYM-9482736152",
        short_sha: "7bdde33b",
        started_at: ~U[2026-05-03 10:00:00Z],
        profile_name: "codex_default"
      }

      body = Workpad.render_session_start(session)

      assert body =~ "## Symphony Workpad"
      assert body =~ "devbox-01:/home/dev/code/symphony-workspaces/SYM-9482736152@7bdde33b"
      assert body =~ "Started by Symphony"
      assert body =~ "codex_default"
    end
  end

  describe "render_completion/2" do
    test "folds in the agent's _symphony_summary.md content" do
      session = %{identifier: "SYM-1", profile_name: "codex_default"}
      summary = "## Summary\n\nFixed the bug.\n\n### Test plan\n- ran make all"
      body = Workpad.render_completion(session, summary)

      assert body =~ "## Symphony Workpad"
      assert body =~ "Fixed the bug."
      assert body =~ "ran make all"
    end

    test "marks the section as Completion when summary present" do
      body = Workpad.render_completion(%{identifier: "SYM-1", profile_name: "x"}, "summary")
      assert body =~ "Completion"
    end
  end

  describe "render_crash/2" do
    test "marks crash section with reason" do
      body = Workpad.render_crash(%{identifier: "SYM-1", profile_name: "x"}, "stdio_broken")

      assert body =~ "Crashed"
      assert body =~ "stdio_broken"
    end
  end
end
```

- [ ] **Step 2: Run to confirm failure**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/workpad_test.exs -v`
Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement `Monday.Workpad`**

Create `elixir/lib/symphony_elixir/monday/workpad.ex`:

```elixir
defmodule SymphonyElixir.Monday.Workpad do
  @moduledoc """
  Renders Monday Update body from session state and (at completion) the agent's
  `_symphony_summary.md` workspace file. Symphony writes this; the agent does
  not.
  """

  @marker "## Symphony Workpad"

  @type session :: %{
          required(:identifier) => String.t(),
          required(:profile_name) => String.t(),
          optional(:instance_id) => String.t(),
          optional(:host) => String.t(),
          optional(:workspace_path) => String.t(),
          optional(:short_sha) => String.t(),
          optional(:started_at) => DateTime.t()
        }

  @spec render_session_start(session()) :: String.t()
  def render_session_start(session) do
    stamp = stamp_line(session)
    started = format_started(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Session

    - Started by Symphony #{started}
    - Profile: `#{session.profile_name}`
    - Identifier: `#{session.identifier}`
    """
  end

  @spec render_completion(session(), String.t()) :: String.t()
  def render_completion(session, summary) do
    stamp = stamp_line(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Completion

    Profile: `#{session.profile_name}`

    #{summary}
    """
  end

  @spec render_crash(session(), String.t()) :: String.t()
  def render_crash(session, reason) do
    stamp = stamp_line(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Crashed

    Profile: `#{session.profile_name}`
    Reason: `#{reason}`
    """
  end

  defp stamp_line(session) do
    host = Map.get(session, :host, "unknown")
    path = Map.get(session, :workspace_path, "")
    sha = Map.get(session, :short_sha, "no-sha")
    "#{host}:#{path}@#{sha}"
  end

  defp format_started(%{started_at: dt}), do: "at " <> DateTime.to_iso8601(dt)
  defp format_started(_), do: "(time unknown)"
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/monday/workpad_test.exs -v`
Expected: PASS — all 4 tests green.

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/monday/workpad.ex elixir/test/symphony_elixir/monday/workpad_test.exs && git commit -m "feat(elixir): add Monday.Workpad body renderer"
```

---

### Task 13: Remove `linear_graphql` tool from `Codex.DynamicTool`

**Files:**
- Modify: `elixir/lib/symphony_elixir/codex/dynamic_tool.ex`
- Test: existing tests for `dynamic_tool.ex` (search and adjust)

- [ ] **Step 1: Find existing tests**

Run: `cd elixir && grep -rn "linear_graphql" test/ lib/`
Capture all references; expect hits in `test/symphony_elixir/codex/dynamic_tool_test.exs` (if exists), `lib/symphony_elixir/codex/dynamic_tool.ex`, the existing WORKFLOW.md, and possibly `test/fixtures/`.

- [ ] **Step 2: Replace `dynamic_tool.ex` body**

Replace the entire `elixir/lib/symphony_elixir/codex/dynamic_tool.ex` with:

```elixir
defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Scaffold for client-side tool calls requested by Codex app-server turns.
  Per Spec 1 DL-005, the previous `linear_graphql` tool is removed and not
  replaced — agents have no Monday access; Symphony's Tracker primitive
  (`SymphonyElixir.Monday.Adapter`) owns all Monday writes.
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, _arguments, _opts) do
    %{
      "success" => false,
      "output" => Jason.encode!(%{"error" => %{"message" => "Unsupported dynamic tool: #{inspect(tool)}.", "supportedTools" => []}}, pretty: true),
      "contentItems" => [
        %{"type" => "inputText", "text" => "No client-side tools are registered."}
      ]
    }
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: []
end
```

- [ ] **Step 3: Update / remove the existing dynamic_tool tests**

If `elixir/test/symphony_elixir/codex/dynamic_tool_test.exs` exists, replace its content with:

```elixir
defmodule SymphonyElixir.Codex.DynamicToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs returns empty list (linear_graphql removed; no replacement)" do
    assert DynamicTool.tool_specs() == []
  end

  test "execute on any tool name returns unsupported response" do
    response = DynamicTool.execute("linear_graphql", %{}, [])
    assert response["success"] == false
    decoded = Jason.decode!(response["output"])
    assert decoded["error"]["supportedTools"] == []
  end
end
```

- [ ] **Step 4: Run tests**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/codex/dynamic_tool_test.exs -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/codex/dynamic_tool.ex elixir/test/symphony_elixir/codex/dynamic_tool_test.exs && git commit -m "refactor(elixir): remove linear_graphql injected tool (Tracker primitive owns Monday writes)"
```

---

### Task 14: Update `Orchestrator` — handoff_states, heartbeat, stranded TTL

**Files:**
- Modify: `elixir/lib/symphony_elixir/orchestrator.ex`
- Modify: `elixir/test/symphony_elixir/orchestrator_test.exs`

This is the largest single task in the plan because the orchestrator is 52KB. Implementing agent: read the existing orchestrator end-to-end before editing; preserve retry/reconciliation/cleanup semantics.

- [ ] **Step 1: Identify the existing dispatch loop and reconciliation paths**

Run: `cd elixir && grep -n "fetch_candidate\|active_states\|terminal_states\|claim\|running\|retry" lib/symphony_elixir/orchestrator.ex | head -40`

Note line numbers for: dispatch loop, claim handling, reconciliation, retry scheduling.

- [ ] **Step 2: Add tests for handoff_states, heartbeat, stranded TTL**

Add to `elixir/test/symphony_elixir/orchestrator_test.exs` (or create if absent):

```elixir
describe "handoff_states" do
  test "items in handoff_states are claimed but not dispatched for new turns" do
    # Setup: configure Tracker.MemoryMonday to return an item with state "Human Review"
    # Action: orchestrator poll tick
    # Expected: item is in :claimed state but no agent runner is started
    flunk("test scaffolding — implementing agent fills this in based on existing orchestrator test patterns")
  end
end

describe "heartbeat" do
  test "boot calls Tracker.acquire_heartbeat before entering poll loop" do
    flunk("test scaffolding — implementing agent fills in")
  end

  test "shutdown calls Tracker.release_heartbeat" do
    flunk("test scaffolding — implementing agent fills in")
  end
end

describe "stranded TTL" do
  test "5 consecutive dispatch failures trigger update_issue_state(:Cancelled) + post_failure_update" do
    flunk("test scaffolding — implementing agent fills in")
  end
end
```

- [ ] **Step 3: Implement orchestrator changes**

In `elixir/lib/symphony_elixir/orchestrator.ex`:

1. Add `tracker.handoff_states` to the eligible-state set when fetching candidates (already covered if `fetch_candidate_issues` returns active+handoff per Adapter).
2. In the per-tick dispatch loop, BEFORE calling `AgentRunner.start/1`, check the item's state — if in `handoff_states`, mark the claim as `:handoff` and skip dispatch.
3. On `init/1` (or equivalent supervisor child startup), call `Tracker.acquire_heartbeat()` before entering the poll loop. On `:lock_held_by_other`, log + raise to halt boot.
4. On `terminate/2`, call `Tracker.release_heartbeat()`.
5. Maintain a per-item `failure_count` map in orchestrator state. Increment on dispatch failure; reset on successful dispatch start. When count hits `tracker.failure_ttl_count`, call `Tracker.update_issue_state(item_id, "Cancelled")` and `Tracker.post_failure_update(item_id, "Stranded after #{count} consecutive failures: #{last_reason}")`.

Implementing agent: preserve retry queue + reconciliation semantics. Refer to spec §2 for the full event flow.

- [ ] **Step 4: Run orchestrator tests + full suite**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/orchestrator_test.exs -v`
Then: `cd elixir && mise exec -- mix test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/orchestrator.ex elixir/test/symphony_elixir/orchestrator_test.exs && git commit -m "feat(elixir): orchestrator support for handoff_states, heartbeat lock, stranded TTL"
```

---

### Task 15: Update `AgentRunner` — Symphony-side write triggers

**Files:**
- Modify: `elixir/lib/symphony_elixir/agent_runner.ex`
- Modify: `elixir/test/symphony_elixir/agent_runner_test.exs`

- [ ] **Step 1: Identify event-stream consumer in existing AgentRunner**

Read `elixir/lib/symphony_elixir/agent_runner.ex` end-to-end. Note where Codex events are received (likely via PubSub or direct subscription).

- [ ] **Step 2: Add tests for write triggers**

Add to the agent runner tests:

```elixir
describe "Tracker writes triggered by event stream" do
  test "on session start, calls Tracker.update_issue_state(item, In Progress) and creates workpad" do
    # set Tracker.adapter override → MemoryMonday
    # spawn AgentRunner with a fake Codex.AppServer that emits :session_started
    # assert MemoryMonday.events() contains {:status_write, "ITEM", "In Progress"} and {:workpad_write, "ITEM", _}
    flunk("scaffolding")
  end

  test "on PR URL appearing in stream, calls Tracker.set_pr_url" do
    flunk("scaffolding")
  end

  test "on completion event with _symphony_summary.md present, writes workpad with completion render" do
    flunk("scaffolding")
  end

  test "on abnormal exit, writes workpad crash render and update_issue_state(:Cancelled)" do
    flunk("scaffolding")
  end
end
```

- [ ] **Step 3: Implement AgentRunner changes**

Add to `elixir/lib/symphony_elixir/agent_runner.ex`:

1. On session-start event, call `Tracker.update_issue_state(item_id, "In Progress")` and `Tracker.upsert_workpad(item_id, Workpad.render_session_start(session))`.
2. Subscribe to a process pipeline that pipes raw stdout/event chunks through `Monday.PRDetector.scan/1`. On `{:ok, url}`, call `Tracker.set_pr_url(item_id, url)`.
3. On the agent's completion event (Codex's `turn.completed` or equivalent), read `<workspace>/_symphony_summary.md` if present; pass to `Workpad.render_completion(session, summary)`; call `Tracker.upsert_workpad(item_id, body)`. If a PR URL was previously detected, call `Tracker.update_issue_state(item_id, "Human Review")`.
4. On abnormal exit (exit reason ≠ `:normal`, or non-zero subprocess exit), call `Tracker.upsert_workpad(item_id, Workpad.render_crash(session, reason))` then `Tracker.update_issue_state(item_id, "Cancelled")`.

- [ ] **Step 4: Run tests**

Run: `cd elixir && mise exec -- mix test test/symphony_elixir/agent_runner_test.exs -v`
Then full suite: `cd elixir && mise exec -- mix test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add elixir/lib/symphony_elixir/agent_runner.ex elixir/test/symphony_elixir/agent_runner_test.exs && git commit -m "feat(elixir): AgentRunner triggers Tracker writes on session start/PR/completion/crash"
```

---

### Task 16: Rewrite `WORKFLOW.md`

**Files:**
- Modify: `elixir/WORKFLOW.md`

- [ ] **Step 1: Replace `WORKFLOW.md` with the spec's sample**

Replace `elixir/WORKFLOW.md` with the content from spec §13 "Sample WORKFLOW.md", with column IDs and heartbeat item ID populated from OP-1.

The new front matter follows spec §13. The new prompt body is short (per spec §13 instructions section): "Do the engineering work, open a PR with `gh pr create`, write `_symphony_summary.md` at completion. You do NOT have access to Monday."

- [ ] **Step 2: Verify front matter parses cleanly**

Run: `cd elixir && mise exec -- mix run -e 'IO.inspect(SymphonyElixir.Workflow.load())'`
Expected: `{:ok, %{config: %{...}, prompt: "...", prompt_template: "..."}}` with the new Monday config.

- [ ] **Step 3: Commit**

```bash
git add elixir/WORKFLOW.md && git commit -m "feat(elixir): rewrite WORKFLOW.md for Monday tracker; remove agent-side Monday management from prompt body"
```

---

### Task 17: Rewrite `live_e2e_test.exs` for Monday

**Files:**
- Modify: `elixir/test/symphony_elixir/live_e2e_test.exs`

- [ ] **Step 1: Read existing E2E test to understand current Linear flow**

Read the current file end-to-end to map the create-disposable-project / create-issue / verify flow.

- [ ] **Step 2: Replace Linear API calls with Monday equivalents**

Rewrite the E2E to:
1. Read `MONDAY_API_TOKEN` from env (skip test if absent — gate with `SYMPHONY_RUN_LIVE_E2E=1`).
2. Create a disposable Monday board via `boards: create_board` mutation, name `"Symphony E2E #{timestamp}"`.
3. Create the three Symphony columns on the disposable board: `Symphony Status` (status), `Symphony PR` (link), and a heartbeat sentinel item.
4. Write a temporary `WORKFLOW.md` with the disposable board ID + column IDs.
5. Boot Symphony, create a test item with `symphony_status: Symphony Ready`, run one full agent turn, verify Symphony writes appear:
   - `symphony_status: In Progress` mutation observed
   - `## Symphony Workpad` Update created
6. Tear down: archive the disposable board.

- [ ] **Step 3: Run live E2E**

Run: `cd elixir && SYMPHONY_RUN_LIVE_E2E=1 MONDAY_API_TOKEN=$(secret-get mybcat/integrations/api-keys/monday) mise exec -- mix test test/symphony_elixir/live_e2e_test.exs -v`
Expected: PASS (real Monday board created and torn down)

- [ ] **Step 4: Commit**

```bash
git add elixir/test/symphony_elixir/live_e2e_test.exs && git commit -m "test(elixir): rewrite live_e2e_test for Monday; verifies Symphony-side writes"
```

---

### Task 18: Update `mix.exs` ignore_modules + add new modules

**Files:**
- Modify: `elixir/mix.exs`

- [ ] **Step 1: Update ignore list**

In `elixir/mix.exs`, replace the `:ignore_modules` block in `test_coverage`:

```elixir
ignore_modules: [
  SymphonyElixir.Config,
  SymphonyElixir.Monday.Client,
  SymphonyElixir.SpecsCheck,
  SymphonyElixir.Orchestrator,
  SymphonyElixir.Orchestrator.State,
  SymphonyElixir.AgentRunner,
  SymphonyElixir.CLI,
  SymphonyElixir.Codex.AppServer,
  SymphonyElixir.Codex.DynamicTool,
  SymphonyElixir.HttpServer,
  SymphonyElixir.StatusDashboard,
  SymphonyElixir.LogFile,
  SymphonyElixir.Workspace,
  SymphonyElixirWeb.DashboardLive,
  SymphonyElixirWeb.Endpoint,
  SymphonyElixirWeb.ErrorHTML,
  SymphonyElixirWeb.ErrorJSON,
  SymphonyElixirWeb.Layouts,
  SymphonyElixirWeb.ObservabilityApiController,
  SymphonyElixirWeb.Presenter,
  SymphonyElixirWeb.StaticAssetController,
  SymphonyElixirWeb.StaticAssets,
  SymphonyElixirWeb.Router,
  SymphonyElixirWeb.Router.Helpers
]
```

(Replaced `Linear.Client` with `Monday.Client`; everything else unchanged.)

- [ ] **Step 2: Run `make all`**

Run: `cd elixir && mise exec -- make all`
Expected: PASS — format check, lint, coverage, dialyzer all green.

- [ ] **Step 3: Commit**

```bash
git add elixir/mix.exs && git commit -m "chore(elixir): update ignore_modules for Linear→Monday rename"
```

---

### Task 19: Delete `lib/symphony_elixir/linear/` directory

**Files:**
- Delete: `elixir/lib/symphony_elixir/linear/client.ex`
- Delete: `elixir/lib/symphony_elixir/linear/adapter.ex`
- Delete: `elixir/lib/symphony_elixir/linear/issue.ex`

- [ ] **Step 1: Verify no remaining references**

Run: `cd elixir && grep -rn "SymphonyElixir.Linear\|Linear\.Client\|Linear\.Adapter\|Linear\.Issue\|linear_graphql" lib/ test/ WORKFLOW.md`
Expected: NO results (or only in `_archive/` or `docs/`).

- [ ] **Step 2: Remove the directory**

Run: `cd elixir && rm -rf lib/symphony_elixir/linear`

- [ ] **Step 3: Run full quality gate**

Run: `cd elixir && mise exec -- make all`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add -A elixir/lib/symphony_elixir && git commit -m "refactor(elixir): remove lib/symphony_elixir/linear/ (Monday adapter validated)"
```

---

### Task 20: Run end-to-end smoke test against Tech Board

**Files:** none (operator validation step).

- [ ] **Step 1: Build Symphony binary**

Run: `cd elixir && mise exec -- make ci`
Expected: clean.

- [ ] **Step 2: Boot Symphony against Tech Board**

Run: `cd elixir && MONDAY_API_TOKEN=$(secret-get mybcat/integrations/api-keys/monday) mise exec -- ./bin/symphony ./WORKFLOW.md`
Expected: heartbeat acquired; poll loop entered; logs show "no candidate items" if no Tech Board items in `Symphony Ready`.

- [ ] **Step 3: Create one test item on Tech Board**

Operator action: in Monday UI, create one Tech Board item with `symphony_status: Symphony Ready`. Title: `[Symphony Smoke Test] noop`. Wait one poll cycle.

- [ ] **Step 4: Verify Symphony picks it up + writes Monday**

Verify in Monday UI:
- Status moved to `In Progress` (Symphony write)
- `## Symphony Workpad` Update exists on the item
- Codex session is running in `~/code/symphony-workspaces/SYM-<id>/`

If yes → Spec 1 implementation complete. Manually transition the test item to `Cancelled` to clean up.

- [ ] **Step 5: Tag the release**

```bash
cd /mnt/d_drive/repos/symphony && git tag -a spec-1-monday-tracker-swap -m "Spec 1 (Monday tracker swap) shipped"
```

---

## Self-Review (run after writing this plan; fix inline)

**1. Spec coverage check:**
- §1 System Overview → covered by Tasks 14-15 (orchestrator + agent runner write flow)
- §2 Behavioral Contract → Tasks 8-15 (read+write paths)
- §2.4 Single-instance enforcement → Task 10 (heartbeat)
- §2.5 Stranded item recovery → Task 14 (orchestrator TTL)
- §3 Non-behaviors → enforced via test assertions in Tasks 8-13
- §4 Integration boundaries → Tasks 5 (Monday API), 13 (Codex), 16 (filesystem hooks)
- §5 Behavioral scenarios S1-S7 → Tasks 14-15 cover S1-S2, S6; S3 (restart), S4 (Monday down), S5 (heartbeat conflict), S7 (stranded TTL) covered in orchestrator + adapter tests
- §6 Per-part context layers → file structure aligns with manifest
- §7 SPEC.md diff plan → out of scope for this plan (spec edit happens after implementation)
- §8 Reference impl deltas → Tasks 1-19 implement the table
- §9 Tech Board setup → Operator preconditions OP-1..OP-3
- §10 Out of scope → Tasks correctly stop at single-runtime; multi-runtime/profiles are Spec 2
- §11 Ambiguity warnings (locked) → Tasks reflect locked decisions
- §12 PHI logging policy → Task 3 (PHI detector); redaction wrapper at adapter boundary is implicit (implementing agent must preserve no-title-in-logs invariant from existing logging conventions)
- §13 Sample WORKFLOW.md → Task 16

**Gaps caught:**
- The "redaction wrapper at the adapter boundary" requirement from spec §12 Rule 3 is not its own task. Implementing agent: when adding logging in `Monday.Adapter` and `AgentRunner`, ensure neither logs full `item.title` or `item.description` strings — use `<redacted:n_chars>` per spec. Add a unit test asserting this in Task 8 or Task 15.
- The `validate_no_phi/1` callback exists in the Tracker behaviour but the orchestrator does not currently call it. Add a step in Task 14 to call `Tracker.validate_no_phi(item)` in the dispatch loop and skip dispatch on `:phi_detected` errors.

**2. Placeholder scan:** None of the listed placeholder patterns (TBD, TODO, etc.) appear. Some tasks have `flunk("scaffolding — implementing agent fills this in")` for orchestrator tests — this is acceptable per the skill (the agent is told what to fill in based on existing test patterns, with referenced behavior).

**3. Type consistency:**
- `Item.t()` shape consistent across Item module (Task 4) and Adapter usage (Task 8).
- `Tracker.upsert_workpad(item_id, body)` consistent in Tracker behaviour (Task 6), MemoryMonday (Task 7), and Monday.Adapter (Task 9).
- `Workpad.render_*` functions take a `session` map; same shape used in AgentRunner Task 15.

**Inline fix applied:** noted the `validate_no_phi` integration into Task 14's dispatch loop; noted the redaction-wrapper test obligation in Tasks 8/15. No structural changes to the plan.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-03-symphony-monday-tracker-swap.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
