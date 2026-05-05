defmodule SymphonyElixir.PRSafetyTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PRSafety
  alias SymphonyElixir.PRSafety.PRState

  defmodule StubGH do
    @moduledoc false
    @behaviour SymphonyElixir.PRSafety.GH

    @impl true
    def pr_view_basic(url) do
      case Process.get({StubGH, :pr_view_basic, url}) do
        nil ->
          case Process.get({StubGH, :pr_view_basic_default}) do
            nil -> {:error, :stub_not_configured}
            response -> response
          end

        response ->
          response
      end
    end

    @impl true
    def pr_head_contains_sha(url, sha) do
      case Process.get({StubGH, :pr_head_contains_sha, url, sha}) do
        nil ->
          case Process.get({StubGH, :pr_head_contains_sha_default}) do
            nil -> {:error, :stub_not_configured}
            response -> response
          end

        response ->
          response
      end
    end

    def stub_pr_view_basic(url, response),
      do: Process.put({__MODULE__, :pr_view_basic, url}, response)

    def stub_pr_head_contains_sha(url, sha, response),
      do: Process.put({__MODULE__, :pr_head_contains_sha, url, sha}, response)

    def stub_pr_view_basic_default(response),
      do: Process.put({__MODULE__, :pr_view_basic_default}, response)
  end

  setup do
    state_path =
      Path.join(System.tmp_dir!(), "pr-safety-test-#{System.unique_integer([:positive])}.json")

    Application.put_env(:symphony_elixir, :pr_safety_state_path, state_path)
    Application.put_env(:symphony_elixir, :pr_safety_gh_module, StubGH)

    on_exit(fn ->
      File.rm(state_path)
      Application.delete_env(:symphony_elixir, :pr_safety_state_path)
      Application.delete_env(:symphony_elixir, :pr_safety_gh_module)
    end)

    %{state_path: state_path}
  end

  describe "evaluate_pr/2 — first detection" do
    test "returns {:ok, :transition} when branch matches the convention" do
      url = "https://github.com/MyBcat/symphony/pull/100"

      StubGH.stub_pr_view_basic(url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-1",
           url: url,
           head_sha: "abc1234"
         }}
      )

      assert {:ok, :transition} = PRSafety.evaluate_pr(url, "11923258050")

      assert {:ok, %{url: ^url, sha: "abc1234"}} = PRState.lookup("11923258050")
    end

    test "returns branch_convention_violation when branch does not match" do
      url = "https://github.com/MyBcat/symphony/pull/101"

      StubGH.stub_pr_view_basic(url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "feature/random-branch",
           url: url,
           head_sha: "deadbeef"
         }}
      )

      assert {:error, {:branch_convention_violation, "feature/random-branch", expected}} =
               PRSafety.evaluate_pr(url, "11923258050")

      assert expected =~ "symphony/SYM-11923258050/attempt-N"
      assert :not_found = PRState.lookup("11923258050")
    end

    test "returns :gh_unavailable when gh fails" do
      url = "https://github.com/MyBcat/symphony/pull/102"

      StubGH.stub_pr_view_basic(url, {:error, {:gh_failed, 1, "auth required"}})

      assert {:error, {:gh_unavailable, _reason}} = PRSafety.evaluate_pr(url, "11923258050")
    end
  end

  describe "evaluate_pr/2 — re-detection (idempotency + force-push)" do
    test "returns idempotent_no_force_push when prior SHA is still in head history" do
      url = "https://github.com/MyBcat/symphony/pull/200"

      :ok = PRState.record("11923258050", %{url: url, sha: "abc1234"})

      StubGH.stub_pr_head_contains_sha(url, "abc1234", {:ok, true})

      assert {:ok, :idempotent_no_force_push} = PRSafety.evaluate_pr(url, "11923258050")
    end

    test "returns force_push_detected when prior SHA is missing from head history" do
      url = "https://github.com/MyBcat/symphony/pull/201"

      :ok = PRState.record("11923258050", %{url: url, sha: "abc1234"})

      StubGH.stub_pr_head_contains_sha(url, "abc1234", {:ok, false})

      assert {:error, :force_push_detected} = PRSafety.evaluate_pr(url, "11923258050")
    end

    test "treats a different URL as fresh first detection" do
      old_url = "https://github.com/MyBcat/symphony/pull/300"
      new_url = "https://github.com/MyBcat/symphony/pull/301"

      :ok = PRState.record("11923258050", %{url: old_url, sha: "abc1234"})

      StubGH.stub_pr_view_basic(new_url,
        {:ok,
         %{
           base_branch: "main",
           head_branch: "symphony/SYM-11923258050/attempt-2",
           url: new_url,
           head_sha: "newshahere"
         }}
      )

      assert {:ok, :transition} = PRSafety.evaluate_pr(new_url, "11923258050")
      assert {:ok, %{url: ^new_url, sha: "newshahere"}} = PRState.lookup("11923258050")
    end

    test "returns :gh_unavailable when ancestry check fails" do
      url = "https://github.com/MyBcat/symphony/pull/202"

      :ok = PRState.record("11923258050", %{url: url, sha: "abc1234"})
      StubGH.stub_pr_head_contains_sha(url, "abc1234", {:error, :network})

      assert {:error, {:gh_unavailable, :network}} = PRSafety.evaluate_pr(url, "11923258050")
    end
  end

  describe "reason_label/1" do
    test "renders branch_convention_violation with got/expected" do
      label =
        PRSafety.reason_label(
          {:branch_convention_violation, "feature/x", "symphony/SYM-1/attempt-N"}
        )

      assert label == "branch_convention_violation: got feature/x, expected symphony/SYM-1/attempt-N"
    end

    test "renders force_push_detected" do
      assert PRSafety.reason_label(:force_push_detected) == "force_push_detected"
    end

    test "renders gh_unavailable label without leaking inner reason" do
      assert PRSafety.reason_label({:gh_unavailable, {:gh_failed, 1, "secret-leak"}}) ==
               "gh_unavailable"
    end
  end
end
