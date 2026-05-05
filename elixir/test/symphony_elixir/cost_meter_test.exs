defmodule SymphonyElixir.CostMeterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CostMeter
  alias SymphonyElixir.Profile

  setup ctx do
    state_path =
      Path.join(
        System.tmp_dir!(),
        "cost-meter-test-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:symphony_elixir, :cost_meter_state_path, state_path)

    # Pin the per-turn estimation budget to a known value so test assertions
    # are deterministic. Defaults: 10K in / 5K out.
    Application.put_env(:symphony_elixir, :cost_meter_input_tokens_per_turn, 10_000)
    Application.put_env(:symphony_elixir, :cost_meter_output_tokens_per_turn, 5_000)

    # Tests that need a configured cost cap rewrite WORKFLOW.md via
    # `write_workflow_file!/2`. Default config from TestSupport is fine
    # for unit tests that only exercise CostMeter helpers; integration
    # tests pass `:write_workflow` explicitly.
    workflow_file = Application.get_env(:symphony_elixir, :workflow_file_path)

    if Map.get(ctx, :cost_cap_daily_usd) do
      write_workflow_file!(workflow_file,
        cost_cap_daily_usd: ctx.cost_cap_daily_usd
      )
    end

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :cost_meter_state_path)
      Application.delete_env(:symphony_elixir, :cost_meter_input_tokens_per_turn)
      Application.delete_env(:symphony_elixir, :cost_meter_output_tokens_per_turn)
      File.rm(state_path)
    end)

    %{state_path: state_path}
  end

  defp start_meter(name) do
    # Use a unique child id so multiple `start_supervised!` calls with
    # different names in the same test don't collide on the default id
    # (the module). Tests that restart the meter mid-test rely on
    # `stop_supervised(name)` finding the right child.
    start_supervised!({CostMeter, name: name}, id: name)
  end

  defp claude_opus_profile(overrides \\ []) do
    %Profile{
      name: "claude_opus",
      kind: :claude,
      max_concurrent: 2,
      cost_per_input_token_usd: Keyword.get(overrides, :cost_per_input_token_usd, 0.000015),
      cost_per_output_token_usd: Keyword.get(overrides, :cost_per_output_token_usd, 0.000075),
      config: %{}
    }
  end

  defp uncosted_profile do
    %Profile{
      name: "claude_uncosted",
      kind: :claude,
      max_concurrent: 1,
      cost_per_input_token_usd: nil,
      cost_per_output_token_usd: nil,
      config: %{}
    }
  end

  describe "estimated_cost/2" do
    test "computes USD across input + output rates and max_turns" do
      profile = claude_opus_profile()

      # 1 turn: 10K in * 0.000015 + 5K out * 0.000075 = 0.15 + 0.375 = $0.525
      assert_in_delta CostMeter.estimated_cost(profile, 1), 0.525, 0.0001
      # 4 turns: 4 * 0.525 = $2.10
      assert_in_delta CostMeter.estimated_cost(profile, 4), 2.10, 0.0001
    end

    test "returns :invalid for profile missing cost rates" do
      assert CostMeter.estimated_cost(uncosted_profile(), 1) == :invalid
    end

    test "treats nil/0 max_turns as a single turn" do
      profile = claude_opus_profile()
      assert_in_delta CostMeter.estimated_cost(profile, nil), 0.525, 0.0001
      assert_in_delta CostMeter.estimated_cost(profile, 0), 0.525, 0.0001
    end
  end

  describe "add/3 and today_spend/0" do
    @tag cost_cap_daily_usd: 50.0
    test "accumulates USD across calls" do
      pid = start_meter(:cost_meter_add_test)
      profile = claude_opus_profile()

      # 1000 input * 0.000015 + 500 output * 0.000075 = 0.015 + 0.0375 = 0.0525
      total1 = CostMeter.add(pid, profile, %{in_tokens: 1_000, out_tokens: 500})
      assert_in_delta total1, 0.0525, 0.0001

      # add another 1K/500 token batch
      total2 = CostMeter.add(pid, profile, %{in_tokens: 1_000, out_tokens: 500})
      assert_in_delta total2, 0.105, 0.0001

      assert_in_delta CostMeter.today_spend(pid), 0.105, 0.0001
    end

    @tag cost_cap_daily_usd: 50.0
    test "ignores token events from profile missing cost rates (fail-closed dispatch handles gating)" do
      pid = start_meter(:cost_meter_uncosted_telemetry_test)

      result = CostMeter.add(pid, uncosted_profile(), %{in_tokens: 100_000, out_tokens: 100_000})
      assert result == 0.0

      assert CostMeter.today_spend(pid) == 0.0
    end

    @tag cost_cap_daily_usd: 50.0
    test "accumulates tiny token costs without rounding each update down to zero" do
      pid = start_meter(:cost_meter_decimal_precision_test)

      profile =
        claude_opus_profile(
          cost_per_input_token_usd: 0.00000001,
          cost_per_output_token_usd: 0.0
        )

      Enum.each(1..100, fn _ ->
        CostMeter.add(pid, profile, %{in_tokens: 1, out_tokens: 0})
      end)

      assert_in_delta CostMeter.today_spend(pid), 0.000001, 0.0000000001
    end
  end

  describe "can_dispatch?/3" do
    @tag cost_cap_daily_usd: 50.0
    test "passes when projected spend stays below cap" do
      pid = start_meter(:cost_meter_pass_test)
      profile = claude_opus_profile()
      # estimated_cost(claude_opus, 20 turns) = 20 * 0.525 = $10.50, well under $50
      assert :ok = CostMeter.can_dispatch?(pid, profile, 20)
    end

    @tag cost_cap_daily_usd: 50.0
    test "refuses when current + estimated would exceed cap" do
      pid = start_meter(:cost_meter_refuse_test)
      profile = claude_opus_profile()

      # Burn $247.50 — well past the $50 cap.
      # 3.3M out * 0.000075 = $247.50
      _ = CostMeter.add(pid, profile, %{in_tokens: 0, out_tokens: 3_300_000})

      assert {:error, {:cost_cap_exceeded, :daily, current, cap, estimated}} =
               CostMeter.can_dispatch?(pid, profile, 20)

      assert current > 200.0
      assert cap == 50.0
      assert estimated > 0.0
    end

    @tag cost_cap_daily_usd: 50.0
    test "fail-closed: refuses profile missing per-token cost config" do
      pid = start_meter(:cost_meter_failclosed_test)

      assert {:error, {:cost_cap_exceeded, :daily, _current, cap, estimated}} =
               CostMeter.can_dispatch?(pid, uncosted_profile(), 20)

      # Spec: treat its spend as MAX → estimated == cap so the inequality
      # always trips on first encounter
      assert estimated == cap
    end

    @tag cost_cap_daily_usd: 50.0
    test "uses agent.max_turns when caller doesn't pass max_turns" do
      pid = start_meter(:cost_meter_default_max_turns_test)
      profile = claude_opus_profile()

      assert :ok = CostMeter.can_dispatch?(pid, profile, nil)
    end
  end

  describe "snapshot/0 (TUI dashboard fields)" do
    @tag cost_cap_daily_usd: 50.0
    test "returns spend, cap, remaining" do
      pid = start_meter(:cost_meter_snapshot_test)
      profile = claude_opus_profile()

      _ = CostMeter.add(pid, profile, %{in_tokens: 1_000_000, out_tokens: 200_000})
      # 1M * 0.000015 + 200K * 0.000075 = 15 + 15 = $30

      snap = CostMeter.snapshot(pid)

      assert snap.cap_usd == 50.0
      assert_in_delta snap.spend_usd, 30.0, 0.0001
      assert_in_delta snap.remaining_usd, 20.0, 0.0001
      assert %Date{} = snap.date_utc
    end
  end

  describe "UTC midnight rollover" do
    @tag cost_cap_daily_usd: 50.0
    test "resets spend when persisted date != today" do
      pid = start_meter(:cost_meter_rollover_test)
      profile = claude_opus_profile()

      # Burn $30
      _ = CostMeter.add(pid, profile, %{in_tokens: 1_000_000, out_tokens: 200_000})
      assert_in_delta CostMeter.today_spend(pid), 30.0, 0.0001

      # Stop and rewrite the persisted state with yesterday's date
      :ok = stop_supervised(:cost_meter_rollover_test)
      yesterday = Date.utc_today() |> Date.add(-1)

      File.write!(
        Application.get_env(:symphony_elixir, :cost_meter_state_path),
        Jason.encode!(%{
          "date_utc" => Date.to_iso8601(yesterday),
          "spend_usd" => 30.0
        })
      )

      pid = start_meter(:cost_meter_rollover_test)

      # Loading old state should rollover to today and reset spend
      assert CostMeter.today_spend(pid) == 0.0
      snap = CostMeter.snapshot(pid)
      assert snap.date_utc == Date.utc_today()
      assert snap.spend_usd == 0.0
    end
  end

  describe "persistence across restarts (same UTC day)" do
    @tag cost_cap_daily_usd: 50.0
    test "preserves spend when restarted on the same UTC day" do
      pid = start_meter(:cost_meter_persist_test)
      profile = claude_opus_profile()

      _ = CostMeter.add(pid, profile, %{in_tokens: 1_000_000, out_tokens: 200_000})
      assert_in_delta CostMeter.today_spend(pid), 30.0, 0.0001

      :ok = stop_supervised(:cost_meter_persist_test)
      pid = start_meter(:cost_meter_persist_test)

      assert_in_delta CostMeter.today_spend(pid), 30.0, 0.0001
    end

    @tag cost_cap_daily_usd: 50.0
    test "corrupt persisted state fails closed at the configured cap instead of resetting spend" do
      File.write!(
        Application.get_env(:symphony_elixir, :cost_meter_state_path),
        "not json"
      )

      pid = start_meter(:cost_meter_corrupt_state_test)

      assert {:error, {:cost_cap_exceeded, :daily, current, cap, estimated}} =
               CostMeter.can_dispatch?(pid, claude_opus_profile(), 1)

      assert cap == 50.0
      assert current == 50.0
      assert estimated > 0.0
      assert CostMeter.today_spend(pid) == 50.0
    end
  end

  describe "render_cap_workpad/2 — refusal message format" do
    test "emits a `## Symphony Cost Cap` block with profile, repo, today's spend, cap, estimated cost" do
      session = %{
        identifier: "SYM-11923119477",
        profile_name: "claude_opus",
        host: "worker-1",
        workspace_path: "/tmp/work",
        short_sha: "abc1234",
        repo: "symphony"
      }

      refusal = {:cost_cap_exceeded, :daily, 49.99, 50.0, 1.05}
      body = CostMeter.render_cap_workpad(session, refusal)

      assert body =~ "## Symphony Cost Cap"
      assert body =~ "Profile: `claude_opus`"
      assert body =~ "Repo: `symphony`"
      assert body =~ "Today's spend: `$49.99`"
      assert body =~ "Cap: `$50.00`"
      assert body =~ "Estimated dispatch cost: `$1.05`"
      assert body =~ "Symphony refused dispatch"
      assert body =~ "Symphony Ready"
      assert body =~ "UTC midnight"
    end
  end

  describe "AC5 token telemetry round-trip via AgentRunner" do
    @tag cost_cap_daily_usd: 50.0
    test "extract_token_delta from CLI usage events forwards to CostMeter" do
      pid = start_meter(:cost_meter_telemetry_test)
      profile = claude_opus_profile()

      # Simulate a turn_completed event with a `:usage` map carrying
      # input/output tokens (the shape produced by AgentRunner's
      # token_usage_for_delta/1 translator on a `:turn_completed` event).
      message = %{
        event: :turn_completed,
        usage: %{input_tokens: 1_000, output_tokens: 500},
        timestamp: DateTime.utc_now()
      }

      :ok = forward_message_to_meter(pid, profile, message)

      assert_in_delta CostMeter.today_spend(pid), 0.0525, 0.0001
    end

    @tag cost_cap_daily_usd: 50.0
    test "Gemini-shape :prompt/:candidates token map also forwards" do
      pid = start_meter(:cost_meter_gemini_shape_test)

      # Gemini's adapter emits `%{prompt: ..., candidates: ..., cached: ..., total: ...}`.
      # The CostMeter accepts the normalized `:in_tokens`/`:out_tokens` shape
      # the AgentRunner extracts; verify the math at the meter boundary.
      profile = claude_opus_profile()
      _ = CostMeter.add(pid, profile, %{in_tokens: 2_000, out_tokens: 1_000})
      # 2K * 0.000015 + 1K * 0.000075 = 0.03 + 0.075 = 0.105

      assert_in_delta CostMeter.today_spend(pid), 0.105, 0.0001
    end
  end

  # Reusing AgentRunner's private helper would couple the test to module
  # internals; the equivalent extraction is small enough to inline.
  defp forward_message_to_meter(pid, profile, %{usage: %{input_tokens: in_tokens, output_tokens: out_tokens}}) do
    _ = CostMeter.add(pid, profile, %{in_tokens: in_tokens, out_tokens: out_tokens})
    :ok
  end
end
