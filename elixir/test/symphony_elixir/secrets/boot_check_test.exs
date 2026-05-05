defmodule SymphonyElixir.Secrets.BootCheckTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Secrets.BootCheck

  @fake_secret_exec Path.expand("../../support/fixtures/fake_secret_exec.py", __DIR__)

  setup do
    on_exit(fn -> Application.delete_env(:symphony_elixir, :secrets_boot_check) end)
    :ok
  end

  test ":skip mode short-circuits and returns :ok" do
    Application.put_env(:symphony_elixir, :secrets_boot_check, :skip)
    assert :ok = BootCheck.run()
  end

  test "no declared secrets short-circuits and skips the AWS probe" do
    Application.put_env(:symphony_elixir, :secrets_boot_check, :enforce)
    write_workflow_file!(Workflow.workflow_file_path())
    assert :ok = BootCheck.run()
  end

  test ":enforce mode passes when every reference resolves" do
    Application.put_env(:symphony_elixir, :secrets_boot_check, :enforce)

    manifest = manifest_with(%{"mybcat/foo" => "value-1", "mybcat/bar" => "value-2"})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo_column_id: "repo",
      secrets_secret_exec_path: @fake_secret_exec,
      repos: %{
        "demo" => %{
          clone_url: "git@github.com:openai/symphony.git",
          secrets: ["mybcat/foo:FOO_TOKEN", "mybcat/bar:BAR_TOKEN"]
        }
      }
    )

    System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest)

    try do
      assert :ok = BootCheck.run()
    after
      File.rm(manifest)
      System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
    end
  end

  test ":enforce mode refuses with structured errors when any reference fails" do
    Application.put_env(:symphony_elixir, :secrets_boot_check, :enforce)

    manifest = manifest_with(%{"mybcat/known" => "value-known"})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo_column_id: "repo",
      secrets_secret_exec_path: @fake_secret_exec,
      repos: %{
        "demo" => %{
          clone_url: "git@github.com:openai/symphony.git",
          secrets: [
            "mybcat/known:KNOWN_TOKEN",
            "mybcat/missing:MISSING_TOKEN"
          ]
        }
      }
    )

    System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest)

    try do
      log =
        capture_log([level: :error], fn ->
          assert {:error, errors} = BootCheck.run()
          assert is_list(errors)

          missing_paths =
            errors
            |> Enum.map(fn {repo, ref, _reason} -> {repo, ref} end)

          assert {"demo", "mybcat/missing:MISSING_TOKEN"} in missing_paths

          # Other (already-resolvable) entries must not appear in the
          # missing list.
          refute {"demo", "mybcat/known:KNOWN_TOKEN"} in missing_paths
        end)

      assert log =~ "Symphony secrets boot check FAILED"
      assert log =~ "mybcat/missing"
      refute log =~ "value-known"
    after
      File.rm(manifest)
      System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
    end
  end

  test ":warn mode logs but returns :ok" do
    Application.put_env(:symphony_elixir, :secrets_boot_check, :warn)

    manifest = manifest_with(%{})

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_repo_column_id: "repo",
      secrets_secret_exec_path: @fake_secret_exec,
      repos: %{
        "demo" => %{
          clone_url: "git@github.com:openai/symphony.git",
          secrets: ["mybcat/missing:MISSING_TOKEN"]
        }
      }
    )

    System.put_env("SYMPHONY_FAKE_SECRETS_PATH", manifest)

    try do
      log =
        capture_log([level: :error], fn ->
          assert :ok = BootCheck.run()
        end)

      assert log =~ "Symphony secrets boot check FAILED"
    after
      File.rm(manifest)
      System.delete_env("SYMPHONY_FAKE_SECRETS_PATH")
    end
  end

  defp manifest_with(map) do
    path =
      Path.join(
        System.tmp_dir!(),
        "symphony-bootcheck-fake-secrets-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(map))
    path
  end
end
