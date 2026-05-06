defmodule SymphonyElixir.AutoMergeTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AutoMerge
  alias SymphonyElixir.AutoMerge.State, as: AutoMergeState
  alias SymphonyElixir.Tracker.{Issue, MemoryMonday}

  defmodule StubGH do
    @moduledoc false
    @behaviour SymphonyElixir.AutoMerge.GH

    @impl true
    def pr_diff_line_count(url) do
      case Process.get({__MODULE__, :pr_diff_line_count, url}) do
        nil -> {:error, :stub_not_configured}
        response -> response
      end
    end

    @impl true
    def pr_view_base(url) do
      case Process.get({__MODULE__, :pr_view_base, url}) do
        nil -> {:error, :stub_not_configured}
        response -> response
      end
    end

    @impl true
    def pr_merge(url) do
      Process.put({__MODULE__, :merge_called?, url}, true)

      case Process.get({__MODULE__, :pr_merge, url}) do
        nil -> :ok
        response -> response
      end
    end

    def stub_pr_diff_line_count(url, response),
      do: Process.put({__MODULE__, :pr_diff_line_count, url}, response)

    def stub_pr_view_base(url, response),
      do: Process.put({__MODULE__, :pr_view_base, url}, response)

    def stub_pr_merge(url, response), do: Process.put({__MODULE__, :pr_merge, url}, response)

    def merge_called?(url), do: Process.get({__MODULE__, :merge_called?, url}, false)
  end

  defmodule StubCodexReview do
    @moduledoc false
    @behaviour SymphonyElixir.CodexReview

    @impl true
    def review(input) do
      Process.put({__MODULE__, :last_input}, input)

      case Process.get({__MODULE__, :review_response}) do
        nil -> {:ok, "Reviewed.\n\nNO BLOCKING ISSUES"}
        response -> response
      end
    end

    def stub_review(response), do: Process.put({__MODULE__, :review_response}, response)
    def last_input, do: Process.get({__MODULE__, :last_input})
  end

  defmodule ToctouTracker do
    @moduledoc """
    Stub Tracker for the M-1 (TOCTOU defense) test. Returns
    "Human Review" on the first `fetch_issue_states_by_ids` call and
    "Cancelled" on every subsequent call, simulating an operator flip
    between gate 5 evaluation and the Merging transition.

    Other Tracker callbacks no-op so AutoMerge can invoke them without
    side effects. The test pid + counter are passed in via
    `:persistent_term` so the stub doesn't need a per-test process.
    """
    @behaviour SymphonyElixir.Tracker

    @impl true
    def fetch_candidate_issues, do: {:ok, []}
    @impl true
    def fetch_candidate_issues_with_phi_findings,
      do: {:ok, %{items: [], phi_offenders: []}}

    @impl true
    def fetch_issues_by_states(_), do: {:ok, []}

    @impl true
    def fetch_issue_states_by_ids(_ids) do
      {test_pid, counter} = :persistent_term.get(:auto_merge_toctou_state)
      :ok = :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)
      send(test_pid, {:fetch_issue_states_call, n})

      state =
        if n >= 2 do
          "Cancelled"
        else
          "Human Review"
        end

      {:ok,
       [
         %SymphonyElixir.Tracker.Issue{
           id: "11923096520",
           identifier: "SYM-11923096520",
           title: "test",
           state: state,
           url: "https://example.org/x",
           assigned_to_worker: true
         }
       ]}
    end

    @impl true
    def update_issue_state(_id, _state), do: :ok
    @impl true
    def upsert_workpad(_id, _body), do: :ok
    @impl true
    def set_pr_url(_id, _url), do: :ok
    @impl true
    def post_failure_update(_id, _body), do: :ok
    @impl true
    def post_pr_refusal(_id, _body), do: :ok
    @impl true
    def post_phi_refusal(_id, _body), do: :ok
    @impl true
    def post_codex_review(_id, _body), do: :ok
    @impl true
    def post_auto_merge_failure(_id, _body), do: :ok
    @impl true
    def acquire_heartbeat, do: :ok
    @impl true
    def release_heartbeat, do: :ok
    @impl true
    def validate_no_phi(_), do: :ok
  end

  @item_id "11923096520"
  @pr_url "https://github.com/MyBcat/symphony/pull/42"

  setup do
    Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
    Application.put_env(:symphony_elixir, :auto_merge_gh_module, StubGH)
    Application.put_env(:symphony_elixir, :codex_review_module, StubCodexReview)

    state_path =
      Path.join(
        System.tmp_dir!(),
        "auto-merge-state-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:symphony_elixir, :auto_merge_state_path, state_path)

    case Process.whereis(MemoryMonday) do
      nil -> {:ok, _} = MemoryMonday.start_link([])
      _pid -> MemoryMonday.reset()
    end

    MemoryMonday.reset()

    # Default item state stays in Human Review for the gate-5 check.
    issue_in_human_review = %Issue{
      id: @item_id,
      identifier: "SYM-11923096520",
      title: "test",
      state: "Human Review",
      url: "https://example.org/issues/x",
      assigned_to_worker: true
    }

    MemoryMonday.set(:item_states_result, {:ok, [issue_in_human_review]})

    on_exit(fn ->
      Application.put_env(:symphony_elixir, :tracker_adapter_override, SymphonyElixir.Tracker.MemoryMonday)
      Application.delete_env(:symphony_elixir, :auto_merge_gh_module)
      Application.delete_env(:symphony_elixir, :codex_review_module)
      Application.delete_env(:symphony_elixir, :auto_merge_state_path)
      File.rm(state_path)
      File.rm(state_path <> ".lock")

      if pid = Process.whereis(MemoryMonday) do
        Process.exit(pid, :normal)
      end
    end)

    repo_entry = %SymphonyElixir.Config.Schema.RepoEntry{
      key: "test-repo",
      auto_merge_on_codex_pass: true,
      auto_merge_max_lines: 500,
      auto_merge_pass_pattern: "NO BLOCKING ISSUES"
    }

    base_ctx = %{
      item_id: @item_id,
      pr_url: @pr_url,
      session: %{
        identifier: "SYM-11923096520",
        profile_name: "codex_gpt55_xhigh",
        host: "test-host",
        workspace_path: "/tmp/work",
        short_sha: "abc1234"
      },
      repo_key: "test-repo",
      repo_entry: repo_entry,
      workspace_path: "/tmp/work",
      base_branch: "main"
    }

    StubGH.stub_pr_diff_line_count(@pr_url, {:ok, 42})

    %{ctx: base_ctx, repo_entry: repo_entry, state_path: state_path}
  end

  describe "build_prompt/1" do
    test "renders the canonical Spec 4 §2.8a review prompt for github.com URLs" do
      prompt = AutoMerge.build_prompt("https://github.com/MyBcat/symphony/pull/42")

      assert prompt =~ "Scrutinize PR 42 on MyBcat/symphony"
      assert prompt =~ "(a) correctness"
      assert prompt =~ "(b) test coverage"
      assert prompt =~ "(c) regressions"
      assert prompt =~ "(d) security/PHI/HIPAA"
      assert prompt =~ "NO BLOCKING ISSUES"
      assert prompt =~ "BLOCKING ISSUES FOUND"
    end

    test "falls back to URL when parse fails" do
      prompt = AutoMerge.build_prompt("not a url")
      assert prompt =~ "Scrutinize PR at not a url"
    end
  end

  describe "evaluate_human_review/1 — happy path" do
    test "all gates pass → Codex review posted, Merging transition, gh pr merge, Done", %{
      ctx: ctx
    } do
      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:codex_review_write, @item_id, body} ->
                 String.contains?(body, "## Symphony Codex Review") and
                   String.contains?(body, "NO BLOCKING ISSUES")

               _ ->
                 false
             end),
             "expected Codex review write; got #{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, @item_id, "Merging"} -> true
               _ -> false
             end),
             "expected status_write Merging; got #{inspect(events)}"

      assert StubGH.merge_called?(@pr_url)

      assert Enum.any?(events, fn
               {:status_write, @item_id, "Done"} -> true
               _ -> false
             end),
             "expected status_write Done; got #{inspect(events)}"

      refute Enum.any?(events, fn
               {:status_write, @item_id, "Rework"} -> true
               _ -> false
             end)

      assert AutoMergeState.reviewed?(@item_id, @pr_url)
    end
  end

  describe "evaluate_human_review/1 — gate failures" do
    test "gate 1 (repo opt-in false) → Codex review still posted, no merge, held", %{ctx: ctx} do
      ctx =
        Map.update!(ctx, :repo_entry, fn entry ->
          %{entry | auto_merge_on_codex_pass: false}
        end)

      assert {:ok, {:held, :repo_opt_in}} = AutoMerge.evaluate_human_review(ctx)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:codex_review_write, @item_id, _body} -> true
               _ -> false
             end)

      refute Enum.any?(events, fn
               {:status_write, @item_id, "Merging"} -> true
               _ -> false
             end)

      refute StubGH.merge_called?(@pr_url)
    end

    test "gate 2 (pass pattern absent) → no merge, held", %{ctx: ctx} do
      StubCodexReview.stub_review({:ok, "Reviewed.\n\nBLOCKING ISSUES FOUND\n1. Bug in foo.ex"})

      assert {:ok, {:held, :codex_pass_pattern}} = AutoMerge.evaluate_human_review(ctx)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:codex_review_write, @item_id, body} ->
                 String.contains?(body, "BLOCKING ISSUES FOUND")

               _ ->
                 false
             end)

      refute Enum.any?(events, fn
               {:status_write, @item_id, "Merging"} -> true
               _ -> false
             end)

      refute StubGH.merge_called?(@pr_url)
    end

    test "gate 3 (PR too large) → no merge, held", %{ctx: ctx} do
      StubGH.stub_pr_diff_line_count(@pr_url, {:ok, 1_000})

      assert {:ok, {:held, :pr_size}} = AutoMerge.evaluate_human_review(ctx)

      refute Enum.any?(MemoryMonday.events(), fn
               {:status_write, @item_id, "Merging"} -> true
               _ -> false
             end)

      refute StubGH.merge_called?(@pr_url)
    end

    test "gate 3 (line count exactly equal to cap) → no merge (strict less-than)", %{ctx: ctx} do
      StubGH.stub_pr_diff_line_count(@pr_url, {:ok, 500})

      assert {:ok, {:held, :pr_size}} = AutoMerge.evaluate_human_review(ctx)
    end

    test "gate 4 (base branch is feature/x, not main/master) → no merge, held", %{ctx: ctx} do
      ctx = Map.put(ctx, :base_branch, "release/2026-05")

      assert {:ok, {:held, :base_branch}} = AutoMerge.evaluate_human_review(ctx)

      refute StubGH.merge_called?(@pr_url)
    end

    test "gate 4 (master is accepted)", %{ctx: ctx} do
      ctx = Map.put(ctx, :base_branch, "master")

      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx)
    end

    test "gate 5 (operator flipped to Rework) → no merge, held", %{ctx: ctx} do
      reworked = %Issue{
        id: @item_id,
        identifier: "SYM-11923096520",
        title: "test",
        state: "Rework",
        url: "https://example.org/x",
        assigned_to_worker: true
      }

      MemoryMonday.set(:item_states_result, {:ok, [reworked]})

      assert {:ok, {:held, :still_in_human_review}} = AutoMerge.evaluate_human_review(ctx)

      refute StubGH.merge_called?(@pr_url)
    end

    test "gate 5 (operator flipped to Cancelled) → no merge, held", %{ctx: ctx} do
      cancelled = %Issue{
        id: @item_id,
        identifier: "SYM-11923096520",
        title: "test",
        state: "Cancelled",
        url: "https://example.org/x",
        assigned_to_worker: true
      }

      MemoryMonday.set(:item_states_result, {:ok, [cancelled]})

      assert {:ok, {:held, :still_in_human_review}} = AutoMerge.evaluate_human_review(ctx)

      refute StubGH.merge_called?(@pr_url)
    end
  end

  describe "evaluate_human_review/1 — symphony repo hardcoded opt-out (Spec 4 §2.8a constraint #5)" do
    test "symphony repo with auto_merge_on_codex_pass: true (a misconfiguration) is still held",
         %{ctx: ctx} do
      # Even if a future operator flips WORKFLOW.md to enable auto-merge
      # for the symphony repo, the gate MUST refuse: the symphony repo's
      # blast radius (orchestrating other repos' merges) is too high.
      misconfigured_repo_entry = %SymphonyElixir.Config.Schema.RepoEntry{
        key: "symphony",
        auto_merge_on_codex_pass: true,
        auto_merge_max_lines: 500,
        auto_merge_pass_pattern: "NO BLOCKING ISSUES"
      }

      ctx = Map.put(ctx, :repo_entry, misconfigured_repo_entry)

      assert {:ok, {:held, :repo_opt_in}} = AutoMerge.evaluate_human_review(ctx)

      refute StubGH.merge_called?(@pr_url)
    end

    test "non-symphony repos respect the auto_merge_on_codex_pass flag", %{ctx: ctx} do
      other_repo_entry = %SymphonyElixir.Config.Schema.RepoEntry{
        key: "client-portal",
        auto_merge_on_codex_pass: true,
        auto_merge_max_lines: 500,
        auto_merge_pass_pattern: "NO BLOCKING ISSUES"
      }

      ctx = Map.put(ctx, :repo_entry, other_repo_entry)

      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx)
    end
  end

  describe "evaluate_human_review/1 — block signal short-circuit (Spec 4 §2.8a B-2)" do
    test "Codex output containing 'BLOCKING ISSUES FOUND' holds even when pass pattern also matches",
         %{ctx: ctx} do
      # Adversarial Codex output: contains both the spec's block signal
      # AND the spec's pass phrase. The block signal MUST win — otherwise
      # a substring match for "NO BLOCKING ISSUES" would let a clearly-
      # blocking review auto-merge.
      adversarial_output = """
      Reviewed PR.

      BLOCKING ISSUES FOUND:
      1. Race condition in gate 5 (TOCTOU window before Merging write).
      2. Auto-merge would proceed despite NO BLOCKING ISSUES being mentioned in the spec.
      """

      StubCodexReview.stub_review({:ok, adversarial_output})

      assert {:ok, {:held, :codex_pass_pattern}} = AutoMerge.evaluate_human_review(ctx)

      refute StubGH.merge_called?(@pr_url)
    end

    test "Codex output without block signal but with pass pattern → merges", %{ctx: ctx} do
      StubCodexReview.stub_review({:ok, "Reviewed PR. All looks good. NO BLOCKING ISSUES"})

      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx)
    end
  end

  describe "evaluate_human_review/1 — TOCTOU defense on Merging (Spec 4 §2.8a M-1)" do
    test "operator flips item out of Human Review between gate evaluation and Merging write → no merge",
         %{ctx: ctx} do
      # Set up a stateful counter so the second `fetch_issue_states_by_ids`
      # call (the one inside do_merge) returns a Cancelled state, while
      # the first call (inside evaluate_gates) still returns Human Review.
      test_pid = self()

      # Spawn a tiny GenServer-ish process to track the call count.
      counter = :counters.new(1, [])
      :persistent_term.put(:auto_merge_toctou_state, {test_pid, counter})

      try do
        Application.put_env(:symphony_elixir, :tracker_adapter_override, ToctouTracker)

        assert {:ok, {:held, :still_in_human_review}} =
                 AutoMerge.evaluate_human_review(ctx)

        # Both fetch calls observed (gate 5 in evaluate_gates, then again in do_merge).
        assert_received {:fetch_issue_states_call, 1}
        assert_received {:fetch_issue_states_call, 2}

        # gh pr merge MUST NOT have been called — the second check caught the flip.
        refute StubGH.merge_called?(@pr_url)
      after
        :persistent_term.erase(:auto_merge_toctou_state)
        Application.put_env(:symphony_elixir, :tracker_adapter_override, MemoryMonday)
      end
    end
  end

  describe "evaluate_human_review/1 — cross-URL idempotency (Spec 4 §2.8a M-6)" do
    test "same item with TWO different PR URLs records both; re-detection of either is idempotent",
         %{ctx: ctx} do
      url_a = "https://github.com/MyBcat/symphony/pull/100"
      url_b = "https://github.com/MyBcat/symphony/pull/200"

      StubGH.stub_pr_diff_line_count(url_a, {:ok, 10})
      StubGH.stub_pr_diff_line_count(url_b, {:ok, 20})

      ctx_a = Map.put(ctx, :pr_url, url_a)
      ctx_b = Map.put(ctx, :pr_url, url_b)

      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx_a)
      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx_b)

      # Both URLs are now in the reviewed set for this item.
      assert AutoMergeState.reviewed?(@item_id, url_a)
      assert AutoMergeState.reviewed?(@item_id, url_b)

      # Re-detection of EITHER url returns idempotent (does NOT clobber
      # the other).
      _ = Process.delete({StubGH, :merge_called?, url_a})
      assert {:ok, :idempotent} = AutoMerge.evaluate_human_review(ctx_a)
      refute StubGH.merge_called?(url_a)

      # The other url remains marked reviewed.
      assert AutoMergeState.reviewed?(@item_id, url_b)
    end
  end

  describe "evaluate_human_review/1 — codex review failures" do
    test "Codex review errors → no merge, failure note posted, item stays in Human Review", %{
      ctx: ctx
    } do
      StubCodexReview.stub_review({:error, :codex_not_found})

      assert {:error, {:codex_review_failed, :codex_not_found}} =
               AutoMerge.evaluate_human_review(ctx)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:codex_review_write, @item_id, body} ->
                 String.contains?(body, "Codex Review Unavailable") and
                   String.contains?(body, "codex_not_found")

               _ ->
                 false
             end),
             "expected Codex review failure write; got #{inspect(events)}"

      refute Enum.any?(events, fn
               {:status_write, @item_id, "Merging"} -> true
               _ -> false
             end)

      refute StubGH.merge_called?(@pr_url)
      refute AutoMergeState.reviewed?(@item_id, @pr_url)
    end
  end

  describe "evaluate_human_review/1 — gh pr merge fails" do
    test "merge action errors → status Rework + Auto-Merge Failed Workpad", %{ctx: ctx} do
      StubGH.stub_pr_merge(
        @pr_url,
        {:error, {:gh_failed, 1, "branch protection rules not satisfied"}}
      )

      assert {:error, {:gh_merge_failed, _}} = AutoMerge.evaluate_human_review(ctx)

      events = MemoryMonday.events()

      assert Enum.any?(events, fn
               {:auto_merge_failure_write, @item_id, body} ->
                 String.contains?(body, "## Symphony Auto-Merge Failed") and
                   String.contains?(body, "branch protection")

               _ ->
                 false
             end),
             "expected auto_merge_failure_write; got #{inspect(events)}"

      assert Enum.any?(events, fn
               {:status_write, @item_id, "Rework"} -> true
               _ -> false
             end),
             "expected status_write Rework; got #{inspect(events)}"
    end
  end

  describe "evaluate_human_review/1 — idempotency" do
    test "second invocation for same (item_id, pr_url) returns :idempotent without re-running",
         %{
           ctx: ctx
         } do
      assert {:ok, :merged} = AutoMerge.evaluate_human_review(ctx)
      # Reset the merge-tracker so we can detect a re-run.
      _ = Process.delete({StubGH, :merge_called?, @pr_url})

      assert {:ok, :idempotent} = AutoMerge.evaluate_human_review(ctx)
      refute StubGH.merge_called?(@pr_url)
    end
  end

  describe "evaluate_human_review/1 — input validation" do
    test "non-github PR url is rejected", %{ctx: ctx} do
      ctx = Map.put(ctx, :pr_url, "https://gitlab.com/foo/bar/pull/1")

      assert {:error, {:invalid_pr_url, _}} = AutoMerge.evaluate_human_review(ctx)
    end

    test "empty ctx returns invalid_ctx" do
      assert {:error, :invalid_ctx} = AutoMerge.evaluate_human_review(%{})
    end
  end

  describe "gates/0" do
    test "returns the documented evaluation order" do
      assert AutoMerge.gates() == [
               :repo_opt_in,
               :codex_pass_pattern,
               :pr_size,
               :base_branch,
               :still_in_human_review
             ]
    end
  end
end
