defmodule SymphonyElixir.Codex.ProjectTrustTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Codex.ProjectTrust

  @env "SYMPHONY_CODEX_CONFIG_TOML"

  setup do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-codex-trust-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(test_root)
    config_path = Path.join(test_root, "config.toml")
    previous = System.get_env(@env)
    System.put_env(@env, config_path)

    on_exit(fn ->
      if is_binary(previous) do
        System.put_env(@env, previous)
      else
        System.delete_env(@env)
      end

      File.rm_rf(test_root)
    end)

    {:ok, %{config_path: config_path, test_root: test_root}}
  end

  describe "config_path/0" do
    test "uses env override when set", %{config_path: config_path} do
      assert ProjectTrust.config_path() == config_path
    end

    test "falls back to ~/.codex/config.toml when env unset" do
      System.delete_env(@env)
      assert ProjectTrust.config_path() == Path.expand("~/.codex/config.toml")
    end

    test "treats an empty env var the same as unset" do
      System.put_env(@env, "")
      assert ProjectTrust.config_path() == Path.expand("~/.codex/config.toml")
    end
  end

  describe "ensure_trusted/1" do
    test "creates the file with a trusted entry when missing", %{config_path: config_path} do
      workspace = "/home/user/symphony-workspaces/SYM-1"

      refute File.exists?(config_path)
      assert :ok = ProjectTrust.ensure_trusted(workspace)
      assert File.exists?(config_path)

      contents = File.read!(config_path)
      assert contents =~ ~s([projects."/home/user/symphony-workspaces/SYM-1"])
      assert contents =~ ~s(trust_level = "trusted")
    end

    test "is idempotent — second call leaves the file unchanged", %{config_path: config_path} do
      workspace = "/home/user/symphony-workspaces/SYM-2"

      assert :ok = ProjectTrust.ensure_trusted(workspace)
      first_mtime = File.stat!(config_path).mtime
      first_contents = File.read!(config_path)

      Process.sleep(1100)

      assert :ok = ProjectTrust.ensure_trusted(workspace)
      second_mtime = File.stat!(config_path).mtime
      second_contents = File.read!(config_path)

      assert second_mtime == first_mtime
      assert second_contents == first_contents
    end

    test "preserves unrelated config and other project entries", %{config_path: config_path} do
      File.write!(config_path, """
      [some_other_section]
      key = "value"

      [projects."/some/other/project"]
      trust_level = "trusted"
      """)

      workspace = "/home/user/symphony-workspaces/SYM-3"
      assert :ok = ProjectTrust.ensure_trusted(workspace)

      contents = File.read!(config_path)
      assert contents =~ ~s([some_other_section])
      assert contents =~ ~s(key = "value")
      assert contents =~ ~s([projects."/some/other/project"])
      assert contents =~ ~s([projects."/home/user/symphony-workspaces/SYM-3"])
      assert contents =~ ~s(trust_level = "trusted")
    end

    test "upgrades a non-trusted entry to trusted in place", %{config_path: config_path} do
      File.write!(config_path, """
      [projects."/home/user/symphony-workspaces/SYM-4"]
      trust_level = "untrusted"
      """)

      assert :ok = ProjectTrust.ensure_trusted("/home/user/symphony-workspaces/SYM-4")

      contents = File.read!(config_path)
      assert contents =~ ~s(trust_level = "trusted")
      refute contents =~ ~s(trust_level = "untrusted")
    end

    test "appends trust_level when section exists without one", %{config_path: config_path} do
      File.write!(config_path, """
      [projects."/home/user/symphony-workspaces/SYM-5"]
      other_setting = 42
      """)

      assert :ok = ProjectTrust.ensure_trusted("/home/user/symphony-workspaces/SYM-5")

      contents = File.read!(config_path)
      assert contents =~ ~s([projects."/home/user/symphony-workspaces/SYM-5"])
      assert contents =~ ~s(trust_level = "trusted")
      assert contents =~ "other_setting = 42"
    end

    test "rejects empty workspace path" do
      assert {:error, {:invalid_workspace, :empty}} = ProjectTrust.ensure_trusted("")
      assert {:error, {:invalid_workspace, :empty}} = ProjectTrust.ensure_trusted("   ")
    end

    test "rejects workspace paths with control characters" do
      assert {:error, {:invalid_workspace, :control_chars}} =
               ProjectTrust.ensure_trusted("/path/with\nnewline")

      assert {:error, {:invalid_workspace, :control_chars}} =
               ProjectTrust.ensure_trusted("/path/with\rcr")

      assert {:error, {:invalid_workspace, :control_chars}} =
               ProjectTrust.ensure_trusted("/path/with\0null")
    end

    test "creates parent directory when missing", %{test_root: test_root} do
      nested_config = Path.join([test_root, "deep", "nested", "config.toml"])
      System.put_env(@env, nested_config)

      refute File.dir?(Path.dirname(nested_config))
      assert :ok = ProjectTrust.ensure_trusted("/home/user/symphony-workspaces/SYM-6")
      assert File.exists?(nested_config)
    end

    test "escapes embedded quotes and backslashes in workspace path", %{config_path: config_path} do
      workspace = ~s(/home/user/work"with-quote\\and-backslash)

      assert :ok = ProjectTrust.ensure_trusted(workspace)

      contents = File.read!(config_path)
      assert contents =~ ~s(/home/user/work\\"with-quote\\\\and-backslash)
    end

    test "surfaces read failure as {:error, {:read_failed, ...}}", %{config_path: config_path} do
      # File.read on a directory fails with :eisdir — exercises the read error
      # branch in read_or_init that's otherwise hidden under default usage.
      File.mkdir_p!(config_path)

      assert {:error, {:read_failed, ^config_path, :eisdir}} =
               ProjectTrust.ensure_trusted("/home/user/symphony-workspaces/SYM-7")
    end

    test "surfaces write failure when atomic .tmp path is already a directory",
         %{test_root: test_root} do
      # Deterministic atomic_write error path: File.write to a path that
      # already exists as a directory fails with :eisdir regardless of user
      # (root or otherwise). This avoids the chmod-vs-root flakiness that
      # would dog a permissions-based variant of the test.
      config_path = Path.join(test_root, "config.toml")
      System.put_env(@env, config_path)

      tmp_path = config_path <> ".symphony.tmp"
      File.mkdir_p!(tmp_path)

      on_exit(fn -> File.rm_rf(tmp_path) end)

      assert {:error, {:write_failed, ^config_path, :eisdir}} =
               ProjectTrust.ensure_trusted("/home/user/symphony-workspaces/SYM-8")
    end

    test "surfaces mkdir failure when parent of config_path is a regular file",
         %{test_root: test_root} do
      blocking_file = Path.join(test_root, "blocker")
      File.write!(blocking_file, "regular file, not a directory")

      # mkdir_p will fail trying to create `blocker/subdir` since `blocker`
      # is a regular file.
      config_under_file = Path.join([blocking_file, "subdir", "config.toml"])
      System.put_env(@env, config_under_file)

      assert {:error, _reason} =
               ProjectTrust.ensure_trusted("/home/user/symphony-workspaces/SYM-9")
    end
  end

  describe "upsert_trust/2 (pure logic)" do
    test "appends a fresh section to empty content" do
      assert {result, :added} = ProjectTrust.upsert_trust("", "/foo/bar")
      assert result =~ ~s([projects."/foo/bar"])
      assert result =~ ~s(trust_level = "trusted")
    end

    test "marks unchanged when section already trusted" do
      content = """
      [projects."/foo/bar"]
      trust_level = "trusted"
      """

      assert {^content, :unchanged} = ProjectTrust.upsert_trust(content, "/foo/bar")
    end

    test "ignores trailing whitespace and comments on already-trusted line" do
      content = """
      [projects."/foo/bar"]
      trust_level = "trusted"   # ok
      """

      assert {^content, :unchanged} = ProjectTrust.upsert_trust(content, "/foo/bar")
    end

    test "tracks updated when changing the trust value" do
      content = """
      [projects."/foo/bar"]
      trust_level = "untrusted"
      """

      assert {result, :updated} = ProjectTrust.upsert_trust(content, "/foo/bar")
      assert result =~ ~s(trust_level = "trusted")
      refute result =~ ~s(trust_level = "untrusted")
    end

    test "does not mutate other [projects.*] sections" do
      content = """
      [projects."/aaa"]
      trust_level = "untrusted"

      [projects."/bbb"]
      trust_level = "untrusted"
      """

      assert {result, :added} = ProjectTrust.upsert_trust(content, "/ccc")
      # Other sections preserved with their original (untrusted) values.
      assert result =~ ~s([projects."/aaa"]\ntrust_level = "untrusted")
      assert result =~ ~s([projects."/bbb"]\ntrust_level = "untrusted")
      assert result =~ ~s([projects."/ccc"]\ntrust_level = "trusted")
    end

    test "preserves trailing blank line spacing when appending" do
      content = "[other]\nkey = 1\n\n"
      # Already ends with \n\n — no extra newline should be inserted.
      assert {result, :added} = ProjectTrust.upsert_trust(content, "/xyz")
      refute String.contains?(result, "\n\n\n[projects")
      assert result =~ ~s([projects."/xyz"]\ntrust_level = "trusted")
    end

    test "appends a leading newline when content has no trailing newline" do
      content = "[other]\nkey = 1"
      assert {result, :added} = ProjectTrust.upsert_trust(content, "/xyz")
      assert result =~ ~s([projects."/xyz"]\ntrust_level = "trusted")
      # Two newlines should now separate the two sections.
      assert String.contains?(result, "key = 1\n\n[projects")
    end

    test "ignores embedded section header references in trust value lookup" do
      # Lines that look like section headers inside another section should
      # terminate the current section's body. This exercises the
      # next_section_index branch that halts at a `[...]` line.
      content = """
      [projects."/foo"]
      trust_level = "trusted"
      [projects."/bar"]
      """

      assert {^content, :unchanged} = ProjectTrust.upsert_trust(content, "/foo")
    end

    test "handles a bare section header at end-of-file with no trailing newline" do
      # Exercises the from_idx >= total branch in next_section_index where
      # the section header is the very last line of the file.
      content = ~s([projects."/foo"])

      assert {result, :updated} = ProjectTrust.upsert_trust(content, "/foo")
      assert result =~ ~s([projects."/foo"])
      assert result =~ ~s(trust_level = "trusted")
    end
  end
end
