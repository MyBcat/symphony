defmodule SymphonyElixir.AutoMerge.StateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.AutoMerge.State

  setup do
    state_path =
      Path.join(System.tmp_dir!(), "auto-merge-state-test-#{System.unique_integer([:positive])}.json")

    Application.put_env(:symphony_elixir, :auto_merge_state_path, state_path)

    on_exit(fn ->
      File.rm(state_path)
      File.rm(state_path <> ".lock")
      Application.delete_env(:symphony_elixir, :auto_merge_state_path)
    end)

    %{state_path: state_path}
  end

  describe "lookup/1" do
    test "returns :not_found when the state file is absent" do
      assert :not_found = State.lookup("11923096520")
    end

    test "returns :not_found for an unknown item id" do
      :ok = State.mark_reviewed("99999", "https://github.com/MyBcat/symphony/pull/1")

      assert :not_found = State.lookup("11923096520")
    end

    test "returns the recorded url + reviewed_at after mark_reviewed/2" do
      url = "https://github.com/MyBcat/symphony/pull/42"
      :ok = State.mark_reviewed("11923096520", url)

      assert {:ok, %{url: ^url, reviewed_at: reviewed_at}} = State.lookup("11923096520")
      assert {:ok, _, _} = DateTime.from_iso8601(reviewed_at)
    end
  end

  describe "reviewed?/2" do
    test "returns false when no record exists" do
      refute State.reviewed?("11923096520", "https://github.com/MyBcat/symphony/pull/42")
    end

    test "returns true when (item_id, url) matches the record exactly" do
      url = "https://github.com/MyBcat/symphony/pull/42"
      :ok = State.mark_reviewed("11923096520", url)

      assert State.reviewed?("11923096520", url)
    end

    test "returns false when item_id matches but url differs" do
      :ok =
        State.mark_reviewed("11923096520", "https://github.com/MyBcat/symphony/pull/42")

      refute State.reviewed?("11923096520", "https://github.com/MyBcat/symphony/pull/43")
    end
  end

  describe "mark_reviewed/2" do
    test "overwrites the prior record on second call (last-write-wins)" do
      old = "https://github.com/MyBcat/symphony/pull/42"
      new = "https://github.com/MyBcat/symphony/pull/43"

      :ok = State.mark_reviewed("11923096520", old)
      :ok = State.mark_reviewed("11923096520", new)

      assert {:ok, %{url: ^new}} = State.lookup("11923096520")
      refute State.reviewed?("11923096520", old)
      assert State.reviewed?("11923096520", new)
    end

    test "rejects empty url" do
      assert {:error, :invalid_arguments} = State.mark_reviewed("11923096520", "")
    end

    test "rejects empty item_id" do
      assert {:error, :invalid_arguments} =
               State.mark_reviewed("", "https://github.com/MyBcat/symphony/pull/42")
    end
  end

  describe "reset!/0" do
    test "removes the state file and lock", %{state_path: state_path} do
      :ok =
        State.mark_reviewed("11923096520", "https://github.com/MyBcat/symphony/pull/42")

      assert File.exists?(state_path)

      :ok = State.reset!()

      refute File.exists?(state_path)
      assert :not_found = State.lookup("11923096520")
    end
  end
end
