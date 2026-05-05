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
    def post_pr_refusal(_, _), do: :ok
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

  test "delegates post_pr_refusal to adapter" do
    assert Tracker.post_pr_refusal("123", "## Symphony PR Refusal\n\nReason: forced") == :ok
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
