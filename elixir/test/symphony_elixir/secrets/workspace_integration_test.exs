defmodule SymphonyElixir.Secrets.WorkspaceIntegrationTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Issue

  @fake_secret_exec Path.expand("../../support/fixtures/fake_secret_exec.py", __DIR__)

  test "after_create runs with .env.symphony sourced" do
    manifest_path =
      Path.join(System.tmp_dir!(), "symphony-ws-secrets-#{System.unique_integer([:positive])}.json")

    File.write!(manifest_path, Jason.encode!(%{"mybcat/test" => "the-resolved-value"}))

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony-ws-secrets-root-#{System.unique_integer([:positive])}")

    template_repo = Path.join(workspace_root, "template")
    File.mkdir_p!(template_repo)
    System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
    System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", template_repo, "config", "user.name", "Test"])
    System.cmd("git", ["-C", template_repo, "commit", "--allow-empty", "-m", "init"])

    after_create = """
    if [ -f ./.env.symphony ]; then chmod_test=ok; else chmod_test=missing; fi
    printf '%s\\n' "$FAKE_SECRET_VAR" > resolved-secret.txt
    printf 'chmod=%s\\n' "$chmod_test" > chmod-result.txt
    """

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_repo_column_id: "repo",
      secrets_secret_exec_path: @fake_secret_exec,
      repos: %{
        "demo-repo" => %{
          clone_url: "https://github.com/openai/symphony.git",
          after_create: after_create,
          secrets: ["mybcat/test:FAKE_SECRET_VAR"]
        }
      },
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-secret-1",
      identifier: "MT-SECRET-1",
      title: "Secrets wired in",
      state: "Symphony Ready",
      repo: "demo-repo"
    }

    System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest_path)

    try do
      # Pre-clone the workspace so the test's after_create step can run without
      # network access. We fake the clone by populating the workspace ourselves
      # and skipping the clone phase via the legacy default-repo path; instead
      # use repos.<key>.clone_url with a local file:// reference.

      assert {:ok, workspace} = simulate_workspace(workspace_root, issue, after_create)

      env_file = Path.join(workspace, ".env.symphony")
      assert File.regular?(env_file)
      {:ok, %File.Stat{mode: mode}} = File.stat(env_file)
      assert Bitwise.band(mode, 0o077) == 0

      assert File.read!(Path.join(workspace, "resolved-secret.txt")) ==
               "the-resolved-value\n"

      assert File.read!(Path.join(workspace, "chmod-result.txt")) ==
               "chmod=ok\n"

      contents = File.read!(env_file)
      assert contents =~ "FAKE_SECRET_VAR='the-resolved-value'"
      refute contents =~ "[REDACTED]"
    after
      System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
      File.rm(manifest_path)
      File.rm_rf(workspace_root)
    end
  end

  test "missing secret refuses dispatch and never writes .env.symphony" do
    manifest_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-ws-secrets-missing-#{System.unique_integer([:positive])}.json"
      )

    File.write!(manifest_path, Jason.encode!(%{}))

    workspace_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-ws-secrets-missing-root-#{System.unique_integer([:positive])}"
      )

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      tracker_repo_column_id: "repo",
      secrets_secret_exec_path: @fake_secret_exec,
      repos: %{
        "demo-repo" => %{
          clone_url: "https://github.com/openai/symphony.git",
          after_create: "echo should-not-run",
          secrets: ["mybcat/missing:UNKNOWN_TOKEN"]
        }
      },
      hook_after_create: nil
    )

    issue = %Issue{
      id: "issue-missing-1",
      identifier: "MT-SECRET-MISSING",
      title: "Secret missing",
      state: "Symphony Ready",
      repo: "demo-repo"
    }

    System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest_path)

    try do
      assert {:error, {:secret_resolution_failed, "demo-repo", _reason}} =
               simulate_workspace(workspace_root, issue, "echo should-not-run")

      workspace = Path.join(workspace_root, "MT-SECRET-MISSING")
      refute File.exists?(Path.join(workspace, ".env.symphony"))
    after
      System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
      File.rm(manifest_path)
      File.rm_rf(workspace_root)
    end
  end

  # The default Spec 3 dispatch path runs `git clone` against the configured
  # `clone_url`. Tests don't have network access, so we simulate clone +
  # secret resolution by side-stepping `Workspace.create_for_issue/2`'s clone
  # phase: pre-create the workspace, then call the secret resolver and
  # after_create hook directly. This still exercises the production wrapping
  # code (Resolver.write_env_file/3 + Resolver.wrap_command/1).
  defp simulate_workspace(workspace_root, issue, after_create) do
    safe_id = String.replace(issue.identifier, ~r/[^a-zA-Z0-9._-]/, "_")
    workspace = Path.join(workspace_root, safe_id)
    File.mkdir_p!(workspace)

    repo = SymphonyElixir.Config.repo!(issue.repo)
    secrets = Map.get(repo, :secrets) || []
    secret_exec_path = SymphonyElixir.Config.secret_exec_path()

    case SymphonyElixir.Secrets.Resolver.write_env_file(secrets, workspace,
           secret_exec_path: secret_exec_path,
           repo_key: issue.repo
         ) do
      :ok ->
        wrapped = SymphonyElixir.Secrets.Resolver.wrap_command(after_create)

        case System.cmd("sh", ["-lc", wrapped], cd: workspace, stderr_to_stdout: true) do
          {_output, 0} -> {:ok, workspace}
          {output, status} -> {:error, {:after_create_failed, status, output}}
        end

      {:error, _reason} = err ->
        err
    end
  end
end
