defmodule SymphonyElixir.PRSafety.PRStateTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.PRSafety.PRState

  setup do
    state_path =
      Path.join(System.tmp_dir!(), "pr-state-test-#{System.unique_integer([:positive])}.json")

    Application.put_env(:symphony_elixir, :pr_safety_state_path, state_path)

    on_exit(fn ->
      File.rm(state_path)
      Application.delete_env(:symphony_elixir, :pr_safety_state_path)
    end)

    %{state_path: state_path}
  end

  describe "lookup/1" do
    test "returns :not_found when the state file does not exist" do
      assert :not_found = PRState.lookup("11923258050")
    end

    test "returns :not_found when the item id is not present" do
      :ok =
        PRState.record("other-item", %{
          url: "https://github.com/MyBcat/symphony/pull/1",
          sha: "abc"
        })

      assert :not_found = PRState.lookup("11923258050")
    end

    test "returns the stored record when present", %{state_path: state_path} do
      :ok =
        PRState.record("11923258050", %{
          url: "https://github.com/MyBcat/symphony/pull/42",
          sha: "deadbeef"
        })

      assert {:ok, %{url: url, sha: sha}} = PRState.lookup("11923258050")
      assert url == "https://github.com/MyBcat/symphony/pull/42"
      assert sha == "deadbeef"
      assert File.exists?(state_path)
    end

    test "is :not_found for empty item id" do
      assert :not_found = PRState.lookup("")
    end
  end

  describe "record/2" do
    test "creates the parent directory if missing", %{state_path: state_path} do
      nested_path = state_path <> ".nested/dir/state.json"
      Application.put_env(:symphony_elixir, :pr_safety_state_path, nested_path)

      assert :ok =
               PRState.record("11923258050", %{
                 url: "https://github.com/MyBcat/symphony/pull/1",
                 sha: "aaa"
               })

      assert File.exists?(nested_path)

      File.rm_rf!(state_path <> ".nested")
    end

    test "overwrites the prior record for the same item" do
      :ok =
        PRState.record("11923258050", %{
          url: "https://github.com/MyBcat/symphony/pull/1",
          sha: "aaa"
        })

      :ok =
        PRState.record("11923258050", %{
          url: "https://github.com/MyBcat/symphony/pull/2",
          sha: "bbb"
        })

      assert {:ok, %{url: "https://github.com/MyBcat/symphony/pull/2", sha: "bbb"}} =
               PRState.lookup("11923258050")
    end

    test "preserves records for other items", %{state_path: _state_path} do
      :ok =
        PRState.record("11923258050", %{
          url: "https://github.com/MyBcat/symphony/pull/1",
          sha: "aaa"
        })

      :ok =
        PRState.record("11923258060", %{
          url: "https://github.com/MyBcat/symphony/pull/2",
          sha: "bbb"
        })

      assert {:ok, %{sha: "aaa"}} = PRState.lookup("11923258050")
      assert {:ok, %{sha: "bbb"}} = PRState.lookup("11923258060")
    end

    test "serializes concurrent writes so records are not lost" do
      tasks =
        for item_id <- ["11923258050", "11923258051", "11923258052", "11923258053"] do
          Task.async(fn ->
            PRState.record(item_id, %{
              url: "https://github.com/MyBcat/symphony/pull/#{item_id}",
              sha: "sha-#{item_id}"
            })
          end)
        end

      assert Enum.all?(Task.await_many(tasks, 10_000), &(&1 == :ok))

      assert {:ok, %{sha: "sha-11923258050"}} = PRState.lookup("11923258050")
      assert {:ok, %{sha: "sha-11923258051"}} = PRState.lookup("11923258051")
      assert {:ok, %{sha: "sha-11923258052"}} = PRState.lookup("11923258052")
      assert {:ok, %{sha: "sha-11923258053"}} = PRState.lookup("11923258053")
    end

    test "rejects invalid records" do
      assert {:error, :invalid_record} = PRState.record("11923258050", %{url: nil, sha: "x"})
      assert {:error, :invalid_record} = PRState.record("", %{url: "u", sha: "x"})
    end
  end

  describe "lookup/1 with corrupt state file" do
    test "returns :error when the file content is not valid JSON", %{state_path: state_path} do
      File.write!(state_path, "this is not json")
      assert {:error, {:state_decode_failed, _}} = PRState.lookup("11923258050")
    end

    test "returns :error when the JSON top-level is not a map", %{state_path: state_path} do
      File.write!(state_path, "[\"not\", \"a\", \"map\"]")
      assert {:error, :invalid_state_file} = PRState.lookup("11923258050")
    end

    test "normalizes malformed per-item records instead of crashing", %{state_path: state_path} do
      File.write!(state_path, ~s({"11923258050":"not a record"}))
      assert {:ok, %{url: "", sha: ""}} = PRState.lookup("11923258050")
    end
  end

  describe "reset!/0" do
    test "removes the state file", %{state_path: state_path} do
      :ok =
        PRState.record("11923258050", %{
          url: "https://github.com/MyBcat/symphony/pull/1",
          sha: "aaa"
        })

      assert File.exists?(state_path)
      assert :ok = PRState.reset!()
      refute File.exists?(state_path)
    end

    test "is a no-op when the state file does not exist", %{state_path: state_path} do
      refute File.exists?(state_path)
      assert :ok = PRState.reset!()
    end
  end
end
