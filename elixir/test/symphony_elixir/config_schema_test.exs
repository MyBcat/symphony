defmodule SymphonyElixir.ConfigSchemaTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule CapturingLoggerHandler do
    @moduledoc false

    def log(event, %{pid: pid} = config) do
      send(pid, {:logger_event, event})
      config
    end
  end

  test "tracker schema accepts Monday config" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "$MONDAY_API_TOKEN",
        "endpoint" => "https://api.monday.com/v2",
        "board_id" => 8_173_460_438,
        "identifier_prefix" => "SYM",
        "symphony_status_column_id" => "status_mkfoo",
        "pr_column_id" => "link_mkbar",
        "heartbeat_item_id" => 1_234_567_890,
        "heartbeat_ttl_ms" => 60_000,
        "complexity_budget_per_tick" => 500,
        "backoff_factor" => 2.0,
        "max_polling_interval_ms" => 60_000,
        "failure_ttl_count" => 5,
        "active_states" => ["Symphony Ready", "In Progress", "Rework"],
        "handoff_states" => ["Human Review", "Merging"],
        "terminal_states" => ["Done", "Cancelled"]
      }
    }

    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
    assert settings.tracker.kind == "monday"
    assert settings.tracker.board_id == 8_173_460_438
    assert settings.tracker.identifier_prefix == "SYM"
    assert settings.tracker.handoff_states == ["Human Review", "Merging"]
  end

  test "Tracker struct inspect redacts api_token" do
    tracker = %SymphonyElixir.Config.Schema.Tracker{
      kind: "monday",
      api_token: "supersecrettoken1234567890",
      board_id: 1,
      symphony_status_column_id: "x"
    }

    rendered = inspect(tracker)
    refute rendered =~ "supersecrettoken1234567890"
    assert rendered =~ "<redacted:"
  end

  test "schema accepts profiles map and agent.default_profile" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "test-token",
        "board_id" => 1,
        "symphony_status_column_id" => "x",
        "heartbeat_item_id" => 999,
        "profile_column_id" => "dropdown_mm30zep"
      },
      "profiles" => %{
        "claude_opus" => %{
          "kind" => "claude",
          "max_concurrent" => 2,
          "claude" => %{
            "command" => "claude --print --output-format stream-json",
            "model" => "claude-opus-4-7",
            "permission_mode" => "acceptEdits"
          }
        },
        "codex_gpt55_xhigh" => %{
          "kind" => "codex",
          "max_concurrent" => 4,
          "codex" => %{
            "command" => "codex app-server",
            "approval_policy" => "never",
            "thread_sandbox" => "workspace-write"
          }
        }
      },
      "agent" => %{
        "default_profile" => "claude_opus",
        "sandbox_safety_floor" => %{
          "claude" => %{"permission_mode" => "acceptEdits"},
          "codex" => %{"thread_sandbox" => "workspace-write", "approval_policy" => "never"}
        }
      }
    }

    assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
    assert settings.tracker.profile_column_id == "dropdown_mm30zep"
    assert settings.agent.default_profile == "claude_opus"
    assert is_map(settings.profiles)
    assert Map.has_key?(settings.profiles, "claude_opus")
    assert settings.profiles["claude_opus"].kind == :claude
    assert settings.profiles["claude_opus"].max_concurrent == 2
    assert settings.profiles["claude_opus"].config["model"] == "claude-opus-4-7"
  end

  test "validate_semantics rejects default_profile not in profiles map" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "x",
        "board_id" => 1,
        "symphony_status_column_id" => "y",
        "profile_column_id" => "profile",
        "heartbeat_item_id" => 999
      },
      "profiles" => %{
        "claude_opus" => %{
          "kind" => "claude",
          "claude" => %{"command" => "claude --print", "permission_mode" => "acceptEdits"}
        }
      },
      "agent" => %{"default_profile" => "missing_profile"}
    }

    {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

    assert {:error, {:default_profile_not_in_profiles_map, "missing_profile"}} =
             SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
  end

  test "validate_semantics rejects unknown profile kind" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "x",
        "board_id" => 1,
        "symphony_status_column_id" => "y",
        "profile_column_id" => "profile",
        "heartbeat_item_id" => 999
      },
      "profiles" => %{"weird" => %{"kind" => "perplexity", "perplexity" => %{"command" => "px"}}},
      "agent" => %{}
    }

    {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

    assert {:error, {:unknown_profile_kind, "weird"}} =
             SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
  end

  test "validate_semantics rejects profiles violating safety floor" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "x",
        "board_id" => 1,
        "symphony_status_column_id" => "y",
        "profile_column_id" => "profile",
        "heartbeat_item_id" => 999
      },
      "profiles" => %{
        "unsafe" => %{
          "kind" => "claude",
          "claude" => %{"command" => "claude --print", "permission_mode" => "bypassPermissions"}
        }
      },
      "agent" => %{
        "sandbox_safety_floor" => %{"claude" => %{"permission_mode" => "acceptEdits"}}
      }
    }

    {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

    assert {:error, {:profile_safety_floor_violation, "unsafe"}} =
             SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
  end

  test "validate_semantics rejects missing Monday profile column" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "x",
        "board_id" => 1,
        "symphony_status_column_id" => "y",
        "heartbeat_item_id" => 999
      }
    }

    {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

    assert {:error, :missing_monday_profile_column} =
             SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
  end

  test "validate_semantics rejects non-positive profile max_concurrent" do
    attrs = %{
      "tracker" => %{
        "kind" => "monday",
        "api_token" => "x",
        "board_id" => 1,
        "symphony_status_column_id" => "y",
        "profile_column_id" => "profile",
        "heartbeat_item_id" => 999
      },
      "profiles" => %{
        "claude_opus" => %{
          "kind" => "claude",
          "max_concurrent" => 0,
          "claude" => %{"command" => "claude --print", "permission_mode" => "acceptEdits"}
        }
      }
    }

    {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

    assert {:error, {:invalid_profile_max_concurrent, "claude_opus"}} =
             SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
  end

  describe "repos config" do
    test "schema parses tracker repo_column_id, repo_policy, and repos map" do
      attrs =
        base_repo_attrs(%{
          "tracker" => %{"repo_column_id" => "repo_dropdown_xyz"},
          "repo_policy" => %{"allowed_clone_hosts" => ["github.com"]},
          "repos" => %{
            "symphony" => %{
              "clone_url" => "git@github.com:openai/symphony.git",
              "after_create" => "mix deps.get",
              "before_remove" => "mix clean",
              "allowed_profiles" => ["claude_opus"],
              "default_branch" => "main"
            }
          }
        })

      assert {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
      assert settings.tracker.repo_column_id == "repo_dropdown_xyz"
      assert settings.repo_policy.allowed_clone_hosts == ["github.com"]
      assert settings.repos["symphony"].clone_url == "git@github.com:openai/symphony.git"
      assert settings.repos["symphony"].after_create == "mix deps.get"
      assert settings.repos["symphony"].before_remove == "mix clean"
      assert settings.repos["symphony"].allowed_profiles == ["claude_opus"]
      assert settings.repos["symphony"].default_branch == "main"
      assert :ok = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
    end

    test "validate_semantics rejects repo missing clone_url" do
      assert_repo_validation_error(
        %{"repos" => %{"symphony" => %{"after_create" => "mix deps.get"}}},
        {:missing_repo_clone_url, "symphony"}
      )
    end

    test "validate_semantics accepts SSH clone_url form" do
      attrs =
        base_repo_attrs(%{
          "tracker" => %{"repo_column_id" => nil},
          "repos" => %{"symphony" => %{"clone_url" => "git@github.com:openai/symphony.git"}}
        })

      {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
      assert :ok = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
    end

    test "validate_semantics accepts HTTPS clone_url form" do
      attrs =
        base_repo_attrs(%{
          "repos" => %{"symphony" => %{"clone_url" => "https://github.com/openai/symphony.git"}}
        })

      {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
      assert :ok = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
    end

    test "validate_semantics rejects clone_url with embedded credentials" do
      assert_repo_validation_error(
        %{
          "repos" => %{
            "symphony" => %{"clone_url" => "https://user:token@github.com/openai/symphony.git"}
          }
        },
        {:unsafe_clone_url, "symphony", :embedded_credentials}
      )
    end

    test "validate_semantics rejects clone_url with shell metacharacters" do
      assert_repo_validation_error(
        %{
          "repos" => %{
            "symphony" => %{"clone_url" => "https://github.com/openai/symphony.git;rm -rf /"}
          }
        },
        {:unsafe_clone_url, "symphony", :shell_metacharacters}
      )
    end

    test "validate_semantics rejects IDN/punycode clone_url host spoofing" do
      assert_repo_validation_error(
        %{
          "repos" => %{
            "symphony" => %{"clone_url" => "https://xn--github-q4a.com/openai/symphony.git"}
          }
        },
        {:unsafe_clone_url, "symphony", :punycode_host}
      )
    end

    test "validate_semantics rejects reviewed clone_url safety floor examples" do
      cases = [
        {"https://github.com\u202Egit/MyBcat/x.git", {:unsafe_clone_url, "symphony", :non_ascii}},
        {"https://user:t@github.com/x.git", {:unsafe_clone_url, "symphony", :embedded_credentials}},
        {"git@github.com:x.git;rm -rf /", {:unsafe_clone_url, "symphony", :shell_metacharacters}},
        {"https://xn--github-q4a.com/x.git", {:unsafe_clone_url, "symphony", :punycode_host}}
      ]

      for {clone_url, expected_reason} <- cases do
        assert_repo_validation_error(
          %{"repos" => %{"symphony" => %{"clone_url" => clone_url}}},
          expected_reason
        )
      end
    end

    test "validate_semantics rejects allowed_profiles not present in profiles map" do
      assert_repo_validation_error(
        %{
          "repos" => %{
            "symphony" => %{
              "clone_url" => "git@github.com:openai/symphony.git",
              "allowed_profiles" => ["missing_profile"]
            }
          }
        },
        {:repo_allowed_profile_not_found, "symphony", "missing_profile"}
      )
    end

    test "validate_semantics rejects non-list allowed_profiles" do
      assert_repo_validation_error(
        %{
          "repos" => %{
            "symphony" => %{
              "clone_url" => "git@github.com:openai/symphony.git",
              "allowed_profiles" => "claude_opus"
            }
          }
        },
        {:invalid_repo_allowed_profiles, "symphony"}
      )
    end

    test "validate_semantics warns when repo_column_id unset and repos are configured" do
      attrs =
        base_repo_attrs(%{
          "repos" => %{"symphony" => %{"clone_url" => "git@github.com:openai/symphony.git"}}
        })

      attrs = pop_in(attrs, ["tracker", "repo_column_id"]) |> elem(1)

      {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

      log =
        capture_log(fn ->
          assert :ok = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
        end)

      assert log =~ "repo_column_id unset; multi-repo dispatch disabled"
      assert log =~ "repos map is ignored"
    end

    test "validate_semantics warns only once per process when repo_column_id is unset" do
      attrs =
        base_repo_attrs(%{
          "repos" => %{"symphony" => %{"clone_url" => "git@github.com:openai/symphony.git"}}
        })

      attrs = pop_in(attrs, ["tracker", "repo_column_id"]) |> elem(1)

      {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)

      log =
        capture_log(fn ->
          assert :ok = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
          assert :ok = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
        end)

      assert (String.split(log, "repo_column_id unset; multi-repo dispatch disabled") |> length()) - 1 == 1
    end
  end

  defp base_repo_attrs(overrides) do
    deep_merge(
      %{
        "tracker" => %{
          "kind" => "monday",
          "api_token" => "x",
          "board_id" => 1,
          "symphony_status_column_id" => "status",
          "profile_column_id" => "profile",
          "repo_column_id" => "repo",
          "heartbeat_item_id" => 999
        },
        "profiles" => %{
          "claude_opus" => %{
            "kind" => "claude",
            "claude" => %{"command" => "claude --print", "permission_mode" => "acceptEdits"}
          }
        }
      },
      overrides
    )
  end

  defp assert_repo_validation_error(overrides, expected_reason) do
    attrs = base_repo_attrs(overrides)
    {:ok, settings} = SymphonyElixir.Config.Schema.parse(attrs)
    assert {:error, ^expected_reason} = SymphonyElixir.Config.Internal.validate_semantics_for_test(settings)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge(left_value, right_value)
    end)
  end

  defp deep_merge(_left, right), do: right
end
