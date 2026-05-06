defmodule SymphonyElixir.Secrets.ResolverTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Secrets.Resolver

  @fake_secret_exec Path.expand("../../support/fixtures/fake_secret_exec.py", __DIR__)

  describe "parse_ref/1" do
    test "accepts <SECRET_ID>:<ENV_VAR> shape" do
      assert {:ok, %{env: "HUBSPOT_TOKEN", secret_id: "mybcat/integrations/hubspot", field: nil}} =
               Resolver.parse_ref("mybcat/integrations/hubspot:HUBSPOT_TOKEN")
    end

    test "accepts optional JSON field as third token" do
      assert {:ok, %{env: "STRIPE_KEY", secret_id: "mybcat/stripe", field: "secret_key"}} =
               Resolver.parse_ref("mybcat/stripe:STRIPE_KEY:secret_key")
    end

    test "rejects blank input" do
      assert {:error, {:invalid_secret_ref, :blank}} = Resolver.parse_ref("")
      assert {:error, {:invalid_secret_ref, :blank}} = Resolver.parse_ref("   ")
    end

    test "rejects unsafe env name" do
      assert {:error, {:invalid_secret_ref, :unsafe_env_name, _}} =
               Resolver.parse_ref("mybcat/foo:9NUMBER_FIRST")
    end

    test "rejects shell metacharacters in secret_id" do
      assert {:error, {:invalid_secret_ref, :unsafe_secret_id, _}} =
               Resolver.parse_ref("mybcat;rm -rf /:HUBSPOT_TOKEN")
    end

    test "rejects newline / control characters" do
      assert {:error, {:invalid_secret_ref, :control_characters}} =
               Resolver.parse_ref("mybcat:FOO\nrm")
    end

    test "rejects too many colons" do
      assert {:error, {:invalid_secret_ref, :unexpected_token_count}} =
               Resolver.parse_ref("a:B:C:D")
    end

    test "rejects non-string input" do
      assert {:error, {:invalid_secret_ref, {:not_a_string, _}}} =
               Resolver.parse_ref(:atom_input)
    end
  end

  describe "parse_refs/1" do
    test "rolls up valid list" do
      refs = ["foo:BAR", "x/y:Z:field"]
      assert {:ok, [%{env: "BAR"}, %{env: "Z"}]} = Resolver.parse_refs(refs)
    end

    test "stops on first error and returns offending raw" do
      refs = ["foo:BAR", "missing-colon", "x:Y"]

      assert {:error, {:invalid_secret_ref, "missing-colon", _reason}} =
               Resolver.parse_refs(refs)
    end

    test "rejects non-list" do
      assert {:error, {:invalid_secrets_list, :not_a_list}} = Resolver.parse_refs("not a list")
    end
  end

  describe "wrap_command/1" do
    test "prepends conditional source of .env.symphony" do
      wrapped = Resolver.wrap_command("echo hi")
      assert wrapped =~ "if [ -f ./.env.symphony ]"
      assert wrapped =~ "set -a"
      assert wrapped =~ ". ./.env.symphony"
      assert wrapped =~ "set +a"
      assert wrapped =~ "set +x"
      assert String.ends_with?(wrapped, "echo hi\n")
    end

    test "sources .env.symphony without xtrace leaking assignment values" do
      workspace = make_workspace!()
      File.write!(Path.join(workspace, ".env.symphony"), "SECRET_TOKEN='xtrace-secret-value'\n")
      File.chmod!(Path.join(workspace, ".env.symphony"), 0o600)

      wrapped = "set -x\n" <> Resolver.wrap_command("printf '%s\\n' ok")
      {output, 0} = System.cmd("sh", ["-lc", wrapped], cd: workspace, stderr_to_stdout: true)

      assert output =~ "ok"
      refute output =~ "xtrace-secret-value"
    end
  end

  describe "declared_env_names/1" do
    test "lists env names, skipping malformed entries" do
      names = Resolver.declared_env_names(["foo:BAR", "bad-no-colon", "x/y:Z:field"])
      assert names == ["BAR", "Z"]
    end
  end

  describe "write_env_file/3 (with fake secret_exec)" do
    setup do
      manifest_path =
        Path.join(System.tmp_dir!(), "symphony-fake-secrets-#{System.unique_integer([:positive])}.json")

      File.write!(
        manifest_path,
        Jason.encode!(%{
          "mybcat/integrations/hubspot" => "fake-hubspot-token-12345-AKIA",
          "mybcat/json-secret" => %{"secret_key" => "fake-stripe-secret-67890"}
        })
      )

      previous = System.get_env("SYMPHONY_FAKE_SECRETS_PATH")
      System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest_path)

      on_exit(fn ->
        File.rm(manifest_path)

        if previous, do: System.put_env("SYMPHONY_FAKE_SECRETS_PATH", previous),
          else: System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
      end)

      :ok
    end

    test "writes .env.symphony with mode 0600 and resolved values" do
      workspace = make_workspace!()

      :ok =
        Resolver.write_env_file(
          [
            "mybcat/integrations/hubspot:HUBSPOT_TOKEN",
            "mybcat/json-secret:STRIPE_KEY:secret_key"
          ],
          workspace,
          secret_exec_path: @fake_secret_exec,
          repo_key: "hubspot-funnel-site"
        )

      env_file = Path.join(workspace, ".env.symphony")
      assert File.regular?(env_file)
      {:ok, %File.Stat{mode: mode}} = File.stat(env_file)
      assert Bitwise.band(mode, 0o077) == 0
      assert Bitwise.band(mode, 0o600) == 0o600

      contents = File.read!(env_file)
      assert contents =~ "HUBSPOT_TOKEN='fake-hubspot-token-12345-AKIA'"
      assert contents =~ "STRIPE_KEY='fake-stripe-secret-67890'"
    end

    test "atomically replaces an existing env file while preserving 0600 mode" do
      workspace = make_workspace!()
      env_file = Path.join(workspace, ".env.symphony")
      File.write!(env_file, "OLD='stale'\n")
      File.chmod!(env_file, 0o644)

      :ok =
        Resolver.write_env_file(
          ["mybcat/integrations/hubspot:HUBSPOT_TOKEN"],
          workspace,
          secret_exec_path: @fake_secret_exec,
          repo_key: "hubspot-funnel-site"
        )

      {:ok, %File.Stat{mode: mode}} = File.stat(env_file)
      assert Bitwise.band(mode, 0o077) == 0
      assert File.read!(env_file) =~ "HUBSPOT_TOKEN='fake-hubspot-token-12345-AKIA'"
      refute File.read!(env_file) =~ "OLD='stale'"
    end

    test "no-ops on empty list and never touches the workspace" do
      workspace = make_workspace!()
      assert :ok = Resolver.write_env_file([], workspace, secret_exec_path: @fake_secret_exec)
      refute File.exists?(Path.join(workspace, ".env.symphony"))
    end

    test "fails with secret_resolution_failed when an entry is missing" do
      workspace = make_workspace!()

      assert {:error, {:secret_resolution_failed, "demo-repo", reason}} =
               Resolver.write_env_file(
                 ["mybcat/does-not-exist:UNKNOWN_TOKEN"],
                 workspace,
                 secret_exec_path: @fake_secret_exec,
                 repo_key: "demo-repo"
               )

      assert match?({:secret_resolution_failed, _status, _output}, reason)
      refute File.exists?(Path.join(workspace, ".env.symphony"))
    end

    test "fails fast on malformed reference and never invokes secret_exec.py" do
      workspace = make_workspace!()

      assert {:error, {:secret_resolution_failed, "demo-repo", {:invalid_secret_ref, "no-colon-here", _}}} =
               Resolver.write_env_file(
                 ["no-colon-here"],
                 workspace,
                 secret_exec_path: @fake_secret_exec,
                 repo_key: "demo-repo"
               )

      refute File.exists?(Path.join(workspace, ".env.symphony"))
    end

    test "fails when secret_exec_path does not exist" do
      workspace = make_workspace!()

      assert {:error, {:secret_resolution_failed, "demo-repo", {:secret_exec_path_missing, _path}}} =
               Resolver.write_env_file(
                 ["mybcat/integrations/hubspot:HUBSPOT_TOKEN"],
                 workspace,
                 secret_exec_path: "/nonexistent/path/secret_exec.py",
                 repo_key: "demo-repo"
               )

      refute File.exists?(Path.join(workspace, ".env.symphony"))
    end

    test "cleans up an unsafe-mode .env.symphony left on disk by a post-write failure" do
      # Simulate the rare race where the Python writer succeeded but a later
      # step in `write_env_file/3` (e.g., chmod denied by a quirky filesystem)
      # erred out. Pre-create a `.env.symphony` and a manifest that's missing
      # one of the requested keys so secret_exec.py exits non-zero AFTER the
      # post-write cleanup branch is exercised. The `cleanup_partial_env_file`
      # helper must remove the file so the caller never sees stale bindings.
      workspace = make_workspace!()
      stale_path = Path.join(workspace, ".env.symphony")
      File.write!(stale_path, "STALE_TOKEN='leftover-from-prior-attempt'\n")
      File.chmod!(stale_path, 0o600)

      assert {:error, {:secret_resolution_failed, "demo-repo", _reason}} =
               Resolver.write_env_file(
                 ["mybcat/does-not-exist:UNKNOWN_TOKEN"],
                 workspace,
                 secret_exec_path: @fake_secret_exec,
                 repo_key: "demo-repo"
               )

      refute File.exists?(stale_path)
    end
  end

  describe "check_one/3 (with fake secret_exec)" do
    setup do
      manifest_path =
        Path.join(System.tmp_dir!(), "symphony-fake-secrets-#{System.unique_integer([:positive])}.json")

      File.write!(
        manifest_path,
        Jason.encode!(%{"mybcat/integrations/hubspot" => "fake-hubspot-token"})
      )

      previous = System.get_env("SYMPHONY_FAKE_SECRETS_PATH")
      System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest_path)

      on_exit(fn ->
        File.rm(manifest_path)

        if previous, do: System.put_env("SYMPHONY_FAKE_SECRETS_PATH", previous),
          else: System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
      end)

      :ok
    end

    test "returns :ok for resolvable references" do
      assert :ok =
               Resolver.check_one(
                 @fake_secret_exec,
                 "mybcat/integrations/hubspot:HUBSPOT_TOKEN",
                 []
               )
    end

    test "returns secret_exec_nonzero with status when path missing" do
      assert {:error, {:secret_exec_nonzero, status, _}} =
               Resolver.check_one(
                 @fake_secret_exec,
                 "mybcat/missing:UNKNOWN_TOKEN",
                 []
               )

      assert is_integer(status) and status != 0
    end
  end

  describe "check_all/2" do
    test "uses :cmd seam to bypass real secret_exec invocation" do
      ok_cmd = fn _python, _args, _opts -> {"", 0} end

      assert :ok =
               Resolver.check_all(
                 %{"r1" => ["x:Y"], "r2" => ["a:B", "c:D"]},
                 secret_exec_path: @fake_secret_exec,
                 cmd: ok_cmd
               )
    end

    test "returns missing tuples when cmd seam reports failure" do
      bad_cmd = fn _python, _args, _opts -> {"resolution failed", 2} end

      assert {:error, errors} =
               Resolver.check_all(
                 %{"hubspot" => ["mybcat/foo:HUBSPOT_TOKEN"]},
                 secret_exec_path: @fake_secret_exec,
                 cmd: bad_cmd
               )

      assert [{"hubspot", "mybcat/foo:HUBSPOT_TOKEN", {:secret_exec_nonzero, 2, _}}] = errors
    end

    test "returns secret_exec_unavailable when wrapper missing" do
      ok_cmd = fn _python, _args, _opts -> {"", 0} end

      assert {:error, [{:secret_exec_unavailable, nil, {:secret_exec_path_missing, _}}]} =
               Resolver.check_all(
                 %{"r" => ["x:Y"]},
                 secret_exec_path: "/nonexistent/secret_exec.py",
                 cmd: ok_cmd
               )
    end
  end

  defp make_workspace! do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-secrets-resolver-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)

    on_exit(fn -> File.rm_rf(path) end)

    path
  end
end
