defmodule SymphonyElixir.FinalizerTest do
  @moduledoc """
  M-0c-D — codex shipping finalizer.

  These tests exercise the Finalizer's decision tree against a stub Shell
  module so the logic is verified without spawning real git/gh subprocesses
  or hitting GitHub. The real System.cmd path is in Finalizer.Shell.Default
  and is only smoke-tested via integration (operator runs a canary after
  merge — see AW-013 in the spec).
  """

  use ExUnit.Case, async: false

  alias SymphonyElixir.Finalizer

  setup do
    table =
      :ets.new(:finalizer_test_calls, [
        :public,
        :duplicate_bag,
        :named_table,
        read_concurrency: false,
        write_concurrency: false
      ])

    on_exit(fn ->
      try do
        :ets.delete(table)
      catch
        _, _ -> :ok
      end
    end)

    %{}
  end

  defmodule StubShell do
    @moduledoc false
    @behaviour SymphonyElixir.Finalizer.Shell

    @impl true
    def git(args, opts) do
      record(:git, args, opts)
      response_for(:git, args)
    end

    @impl true
    def gh(args, opts) do
      record(:gh, args, opts)
      response_for(:gh, args)
    end

    defp record(kind, args, opts) do
      :ets.insert(:finalizer_test_calls, {{kind, args}, opts})
    end

    defp response_for(kind, args) do
      key = {:response, kind, args}

      case :ets.lookup(:finalizer_test_calls, key) do
        [{^key, response}] -> response
        _ -> {:ok, ""}
      end
    end
  end

  defp set_response(kind, args, response) do
    :ets.insert(:finalizer_test_calls, {{:response, kind, args}, response})
  end

  defp recorded?(kind, args) do
    :ets.lookup(:finalizer_test_calls, {kind, args}) != []
  end

  defp call_count(kind) do
    :ets.match_object(:finalizer_test_calls, {{kind, :_}, :_}) |> length()
  end

  defp base_input(overrides \\ %{}) do
    Map.merge(
      %{
        workspace: "/tmp/symphony-test/SYM-12345",
        issue_id: "12345",
        issue_identifier: "SYM-12345",
        issue_title: "Update bio on website",
        issue_description: "Change Dr. Smith's bio.",
        profile_kind: :codex,
        profile_name: "codex_gpt55_xhigh",
        base_branch: "main",
        shell: StubShell
      },
      overrides
    )
  end

  describe "non-codex profiles" do
    test "T-007: claude profile returns :not_a_codex_profile no-op" do
      input = base_input(%{profile_kind: :claude, profile_name: "claude_opus"})

      assert {:noop, :not_a_codex_profile} = Finalizer.finalize(input)
      assert call_count(:git) == 0
      assert call_count(:gh) == 0
    end

    test "gemini profile returns :not_a_codex_profile no-op" do
      input = base_input(%{profile_kind: :gemini, profile_name: "gemini_2.5"})

      assert {:noop, :not_a_codex_profile} = Finalizer.finalize(input)
      assert call_count(:git) == 0
    end
  end

  describe "decision tree on codex profile" do
    test "T-001 success: commits exist, no PR yet, opens PR" do
      input = base_input()
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "3"})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, "pushed"})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:ok, "AnkitClassicVision/cvc-new-site"})

      set_response(
        :gh,
        ["pr", "list", "--repo", "AnkitClassicVision/cvc-new-site", "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[0].url // empty"],
        {:ok, ""}
      )

      set_response(
        :gh,
        ["pr", "create", "--repo", "AnkitClassicVision/cvc-new-site", "--base", "main",
         "--head", branch, "--title",
         "SYM-12345: Update bio on website",
         "--body",
         "Closes Monday item SYM-12345.\nSymphony profile: codex_gpt55_xhigh.\n\nChange Dr. Smith's bio.\n\n<!-- symphony-finalizer:M-0c-D -->"],
        {:ok, "https://github.com/AnkitClassicVision/cvc-new-site/pull/42"}
      )

      assert {:ok, %{pr_url: pr_url, branch: ^branch}} = Finalizer.finalize(input)
      assert pr_url == "https://github.com/AnkitClassicVision/cvc-new-site/pull/42"
      assert recorded?(:git, ["push", "-u", "origin", branch])
      assert recorded?(:gh, ["pr", "create", "--repo", "AnkitClassicVision/cvc-new-site",
        "--base", "main", "--head", branch, "--title",
        "SYM-12345: Update bio on website",
        "--body",
        "Closes Monday item SYM-12345.\nSymphony profile: codex_gpt55_xhigh.\n\nChange Dr. Smith's bio.\n\n<!-- symphony-finalizer:M-0c-D -->"])
    end

    test "T-002 no commits: returns :no_commits no-op" do
      input = base_input()

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, "main"})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "0"})

      assert {:noop, :no_commits} = Finalizer.finalize(input)
      refute recorded?(:git, ["push", "-u", "origin", "symphony/SYM-12345/attempt-1"])
      assert call_count(:gh) == 0
    end

    test "T-003 uncommitted changes: returns :uncommitted_changes error" do
      input = base_input()

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, "symphony/SYM-12345/attempt-1"})

      set_response(:git, ["status", "--porcelain"], {:ok, " M lib/foo.ex\n?? bar.txt"})

      assert {:error, {:uncommitted_changes, count}} = Finalizer.finalize(input)
      assert count == 2
      refute recorded?(:git, ["rev-list", "--count", "main..HEAD"])
    end

    test "T-004 PR already open: returns :pr_already_open no-op" do
      input = base_input()
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "1"})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, "Everything up-to-date"})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:ok, "AnkitClassicVision/cvc-new-site"})

      set_response(
        :gh,
        ["pr", "list", "--repo", "AnkitClassicVision/cvc-new-site", "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[0].url // empty"],
        {:ok, "https://github.com/AnkitClassicVision/cvc-new-site/pull/40"}
      )

      assert {:noop, :pr_already_open, "https://github.com/AnkitClassicVision/cvc-new-site/pull/40"} =
               Finalizer.finalize(input)

      refute recorded?(:gh, [
               "pr",
               "create",
               "--repo",
               "AnkitClassicVision/cvc-new-site",
               "--base",
               "main",
               "--head",
               branch,
               "--title",
               "SYM-12345: Update bio on website",
               "--body",
               "Closes Monday item SYM-12345.\nSymphony profile: codex_gpt55_xhigh.\n\nChange Dr. Smith's bio.\n\n<!-- symphony-finalizer:M-0c-D -->"
             ])
    end

    test "T-005 push rejected non-FF: returns :push_rejected_non_ff error, no force-push" do
      input = base_input()
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "1"})

      set_response(:git, ["push", "-u", "origin", branch],
        {:error,
         {1,
          "To github.com:Ankit/repo.git\n ! [rejected]        symphony/SYM-12345/attempt-1 -> symphony/SYM-12345/attempt-1 (non-fast-forward)\nerror: failed to push some refs.\nhint: Updates were rejected because the remote contains work that you do not have locally."}}
      )

      assert {:error, {:push_rejected_non_ff, ^branch}} = Finalizer.finalize(input)
      refute recorded?(:git, ["push", "--force", "-u", "origin", branch])
      refute recorded?(:git, ["push", "--force-with-lease", "-u", "origin", branch])
      assert call_count(:gh) == 0
    end

    test "T-006 gh repo view fails: returns :gh_repo_view_failed error" do
      input = base_input()
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "1"})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, ""})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:error, {1, "gh: not authenticated. Run `gh auth login`."}})

      assert {:error, {:gh_repo_view_failed, _}} = Finalizer.finalize(input)
      refute recorded?(:gh, [
               "pr",
               "list",
               "--repo",
               "AnkitClassicVision/cvc-new-site",
               "--head",
               branch,
               "--state",
               "open",
               "--json",
               "url",
               "--jq",
               ".[0].url // empty"
             ])
    end
  end

  describe "branch detection on main" do
    test "creates work branch when HEAD is on base branch" do
      input = base_input()
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, "main"})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "2"})
      set_response(:git, ["switch", "-C", branch], {:ok, ""})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, ""})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:ok, "AnkitClassicVision/cvc-new-site"})

      set_response(
        :gh,
        ["pr", "list", "--repo", "AnkitClassicVision/cvc-new-site", "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[0].url // empty"],
        {:ok, ""}
      )

      set_response(
        :gh,
        ["pr", "create", "--repo", "AnkitClassicVision/cvc-new-site", "--base", "main",
         "--head", branch, "--title",
         "SYM-12345: Update bio on website",
         "--body",
         "Closes Monday item SYM-12345.\nSymphony profile: codex_gpt55_xhigh.\n\nChange Dr. Smith's bio.\n\n<!-- symphony-finalizer:M-0c-D -->"],
        {:ok, "https://github.com/AnkitClassicVision/cvc-new-site/pull/43"}
      )

      assert {:ok, %{pr_url: _, branch: ^branch}} = Finalizer.finalize(input)
      assert recorded?(:git, ["switch", "-C", branch])
    end
  end

  describe "title and body trimming" do
    test "title is truncated to 64 chars after the SYM-id prefix" do
      long_title = String.duplicate("X", 200)
      input = base_input(%{issue_title: long_title})
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "1"})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, ""})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:ok, "AnkitClassicVision/cvc-new-site"})

      set_response(
        :gh,
        ["pr", "list", "--repo", "AnkitClassicVision/cvc-new-site", "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[0].url // empty"],
        {:ok, ""}
      )

      _ = Finalizer.finalize(input)

      pr_create_calls =
        :ets.match_object(:finalizer_test_calls, {{:gh, :_}, :_})
        |> Enum.filter(fn {{:gh, args}, _} -> match?(["pr", "create" | _], args) end)

      assert length(pr_create_calls) == 1

      [{{:gh, args}, _}] = pr_create_calls
      title_idx = Enum.find_index(args, &(&1 == "--title")) + 1
      title = Enum.at(args, title_idx)

      assert String.starts_with?(title, "SYM-12345: ")
      truncated_part = String.replace_prefix(title, "SYM-12345: ", "")
      assert String.length(truncated_part) <= 64
    end

    test "description longer than 1000 chars is truncated in body" do
      long_desc = String.duplicate("Y", 1500)
      input = base_input(%{issue_description: long_desc})
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "1"})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, ""})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:ok, "AnkitClassicVision/cvc-new-site"})

      set_response(
        :gh,
        ["pr", "list", "--repo", "AnkitClassicVision/cvc-new-site", "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[0].url // empty"],
        {:ok, ""}
      )

      _ = Finalizer.finalize(input)

      [{{:gh, args}, _}] =
        :ets.match_object(:finalizer_test_calls, {{:gh, :_}, :_})
        |> Enum.filter(fn {{:gh, args}, _} -> match?(["pr", "create" | _], args) end)

      body_idx = Enum.find_index(args, &(&1 == "--body")) + 1
      body = Enum.at(args, body_idx)

      assert String.contains?(body, "Closes Monday item SYM-12345.")
      assert String.contains?(body, "<!-- symphony-finalizer:M-0c-D -->")
      desc_segment_length = String.length(body) - String.length("Closes Monday item SYM-12345.\nSymphony profile: codex_gpt55_xhigh.\n\n") - String.length("\n\n<!-- symphony-finalizer:M-0c-D -->")
      assert desc_segment_length <= 1000
    end
  end

  describe "idempotency" do
    test "T-010: invoking twice on workspace with existing PR returns same noop both times" do
      input = base_input()
      branch = "symphony/SYM-12345/attempt-1"

      set_response(:git, ["rev-parse", "--abbrev-ref", "HEAD"], {:ok, branch})
      set_response(:git, ["status", "--porcelain"], {:ok, ""})
      set_response(:git, ["rev-list", "--count", "main..HEAD"], {:ok, "1"})
      set_response(:git, ["push", "-u", "origin", branch], {:ok, "Everything up-to-date"})

      set_response(:gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
        {:ok, "AnkitClassicVision/cvc-new-site"})

      set_response(
        :gh,
        ["pr", "list", "--repo", "AnkitClassicVision/cvc-new-site", "--head", branch,
         "--state", "open", "--json", "url", "--jq", ".[0].url // empty"],
        {:ok, "https://github.com/AnkitClassicVision/cvc-new-site/pull/40"}
      )

      assert {:noop, :pr_already_open, url1} = Finalizer.finalize(input)
      assert {:noop, :pr_already_open, url2} = Finalizer.finalize(input)
      assert url1 == url2
    end
  end
end
