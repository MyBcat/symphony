defmodule SymphonyElixir.PRSafety.GH.DefaultTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PRSafety.GH.Default

  setup do
    test_root =
      Path.join(System.tmp_dir!(), "gh-default-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(test_root)

    gh = Path.join(test_root, "gh")
    trace = Path.join(test_root, "gh.trace")
    previous_path = System.get_env("PATH")
    previous_mode = System.get_env("SYMP_TEST_GH_MODE")
    previous_trace = System.get_env("SYMP_TEST_GH_TRACE")

    File.write!(gh, """
    #!/bin/sh
    printf '%s\\n' "$*" >> "${SYMP_TEST_GH_TRACE}"

    if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
      case "${SYMP_TEST_GH_MODE}" in
        basic_ok)
          printf '%s\\n' '{"baseRefName":"main","headRefName":"symphony/SYM-11923258050/attempt-1","url":"https://github.com/MyBcat/symphony/pull/42","headRefOid":"abc123"}'
          exit 0
          ;;
        basic_missing_sha)
          printf '%s\\n' '{"baseRefName":"main","headRefName":"symphony/SYM-11923258050/attempt-1","url":"https://github.com/MyBcat/symphony/pull/42"}'
          exit 0
          ;;
        compare_ahead|compare_identical|compare_diverged|compare_404)
          printf '%s\\n' '{"baseRefName":"main","headRefName":"symphony/SYM-11923258050/attempt-1","url":"https://github.com/MyBcat/symphony/pull/42","headRefOid":"newsha"}'
          exit 0
          ;;
        malformed)
          printf '%s\\n' 'not json'
          exit 0
          ;;
        fail)
          printf '%s\\n' 'auth required'
          exit 2
          ;;
      esac
    fi

    if [ "$1" = "api" ]; then
      case "${SYMP_TEST_GH_MODE}" in
        compare_ahead)
          printf '%s\\n' 'ahead'
          exit 0
          ;;
        compare_identical)
          printf '%s\\n' 'identical'
          exit 0
          ;;
        compare_diverged)
          printf '%s\\n' 'diverged'
          exit 0
          ;;
        compare_404)
          printf '%s\\n' 'gh: Not Found (HTTP 404)' >&2
          exit 1
          ;;
      esac
    fi

    printf '%s\\n' "unexpected mode ${SYMP_TEST_GH_MODE}" >&2
    exit 99
    """)

    File.chmod!(gh, 0o755)
    System.put_env("PATH", test_root <> ":" <> (previous_path || ""))
    System.put_env("SYMP_TEST_GH_TRACE", trace)

    on_exit(fn ->
      restore_env("PATH", previous_path)
      restore_env("SYMP_TEST_GH_MODE", previous_mode)
      restore_env("SYMP_TEST_GH_TRACE", previous_trace)
      File.rm_rf(test_root)
    end)

    %{trace: trace}
  end

  test "pr_view_basic shells out to gh pr view and parses required fields", %{trace: trace} do
    System.put_env("SYMP_TEST_GH_MODE", "basic_ok")

    assert {:ok,
            %{
              base_branch: "main",
              head_branch: "symphony/SYM-11923258050/attempt-1",
              url: "https://github.com/MyBcat/symphony/pull/42",
              head_sha: "abc123"
            }} = Default.pr_view_basic("https://github.com/MyBcat/symphony/pull/42")

    assert File.read!(trace) =~
             "pr view https://github.com/MyBcat/symphony/pull/42 --json baseRefName,headRefName,url,headRefOid"
  end

  test "pr_view_basic treats malformed JSON and missing head SHA as unavailable" do
    System.put_env("SYMP_TEST_GH_MODE", "malformed")
    assert {:error, {:gh_decode_failed, _}} = Default.pr_view_basic("https://github.com/MyBcat/symphony/pull/42")

    System.put_env("SYMP_TEST_GH_MODE", "basic_missing_sha")

    assert {:error, {:unexpected_gh_payload, :missing_fields}} =
             Default.pr_view_basic("https://github.com/MyBcat/symphony/pull/42")
  end

  test "pr_view_basic reports non-zero gh exits and missing gh on PATH" do
    System.put_env("SYMP_TEST_GH_MODE", "fail")

    assert {:error, {:gh_failed, 2, "auth required"}} =
             Default.pr_view_basic("https://github.com/MyBcat/symphony/pull/42")

    System.put_env("PATH", "")
    assert {:error, {:gh_unavailable, _}} = Default.pr_view_basic("https://github.com/MyBcat/symphony/pull/42")
  end

  test "pr_head_contains_sha checks ancestry via GitHub compare status", %{
    trace: trace
  } do
    System.put_env("SYMP_TEST_GH_MODE", "compare_ahead")

    assert {:ok, true} =
             Default.pr_head_contains_sha("https://github.com/MyBcat/symphony/pull/42", "oldsha")

    assert File.read!(trace) =~
             "api repos/MyBcat/symphony/compare/oldsha...newsha --jq .status"
  end

  test "pr_head_contains_sha treats identical head as contained without compare", %{trace: trace} do
    System.put_env("SYMP_TEST_GH_MODE", "basic_ok")

    assert {:ok, true} =
             Default.pr_head_contains_sha("https://github.com/MyBcat/symphony/pull/42", "abc123")

    refute File.read!(trace) =~ "api "
  end

  test "pr_head_contains_sha detects rewritten history and orphaned SHAs" do
    System.put_env("SYMP_TEST_GH_MODE", "compare_diverged")

    assert {:ok, false} =
             Default.pr_head_contains_sha("https://github.com/MyBcat/symphony/pull/42", "oldsha")

    System.put_env("SYMP_TEST_GH_MODE", "compare_404")

    assert {:ok, false} =
             Default.pr_head_contains_sha("https://github.com/MyBcat/symphony/pull/42", "oldsha")
  end

  test "pr_head_contains_sha rejects malformed PR URLs before invoking gh", %{trace: trace} do
    System.put_env("SYMP_TEST_GH_MODE", "compare_ahead")

    assert {:error, {:invalid_pr_url, "https://example.com/not/github"}} =
             Default.pr_head_contains_sha("https://example.com/not/github", "oldsha")

    refute File.exists?(trace)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
