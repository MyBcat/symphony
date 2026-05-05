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
      Application.delete_env(:symphony_elixir, :tracker_adapter_override)
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
      key: "symphony",
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
      repo_key: "symphony",
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
