defmodule SymphonyElixir.Secrets.ScrubberTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Secrets.Scrubber

  describe "scrub/2 — pattern redaction" do
    # Test fixtures are built via String.duplicate / interpolation so the
    # literal token shapes never appear in source as a single token. This
    # keeps GitHub's secret-scanning push protection happy while still
    # exercising the Scrubber's regex against real-shaped strings.

    test "redacts AWS access key id" do
      key = "AKIA" <> String.duplicate("Z", 16)
      line = "Using #{key} for upload"
      assert Scrubber.scrub(line) == "Using [REDACTED] for upload"
    end

    test "redacts AWS temporary access key id" do
      key = "ASIA" <> String.duplicate("Z", 16)
      line = "Using #{key} for upload"
      assert Scrubber.scrub(line) == "Using [REDACTED] for upload"
    end

    test "redacts GitHub fine-grained token" do
      key = "ghp_" <> String.duplicate("Z", 36)
      line = ~s(GIT_TOKEN="#{key}")
      assert Scrubber.scrub(line) == ~s(GIT_TOKEN="[REDACTED]")
    end

    test "redacts Stripe live key" do
      key = "sk_" <> "live_" <> String.duplicate("Z", 30)
      line = "STRIPE=#{key} # billing"
      assert Scrubber.scrub(line) == "STRIPE=[REDACTED] # billing"
    end

    test "redacts Bearer header" do
      token = String.duplicate("Z", 24)
      line = "Authorization: Bearer #{token}"
      scrubbed = Scrubber.scrub(line)
      assert scrubbed == "[REDACTED]"
    end

    test "redacts Basic authorization header" do
      token = String.duplicate("Z", 24)
      line = "Authorization: Basic #{token}"
      assert Scrubber.scrub(line) == "[REDACTED]"
    end

    test "redacts generic api_key and token assignments" do
      api_key = String.duplicate("A", 20)
      token = String.duplicate("B", 20)
      line = "api_key=#{api_key} token: #{token}"
      scrubbed = Scrubber.scrub(line)

      refute scrubbed =~ api_key
      refute scrubbed =~ token
      assert scrubbed =~ "[REDACTED]"
    end

    test "redacts AWS env assignment forms" do
      access_key = "AKIA" <> String.duplicate("A", 16)
      secret_key = String.duplicate("B", 40)
      session_token = String.duplicate("C", 24)

      line =
        "AWS_ACCESS_KEY_ID=#{access_key} aws_secret_access_key=#{secret_key} " <>
          "AWS_SESSION_TOKEN=#{session_token}"

      scrubbed = Scrubber.scrub(line)

      refute scrubbed =~ access_key
      refute scrubbed =~ secret_key
      refute scrubbed =~ session_token
      assert scrubbed =~ "[REDACTED]"
    end

    test "redacts Anthropic key" do
      key = "sk-" <> "ant-" <> String.duplicate("Z", 28)
      line = "key: #{key}"
      assert Scrubber.scrub(line) == "key: [REDACTED]"
    end

    test "leaves UUIDs and short identifiers alone" do
      line = "request id 4b2a8c7f-2e8b-4c5a-9d3a-1234567890ab finished"
      assert Scrubber.scrub(line) == line
    end
  end

  describe "scrub/2 — literal redaction" do
    test "replaces every occurrence of the literal value" do
      line = "TOKEN=super-secret-value123 leaked super-secret-value123"
      scrubbed = Scrubber.scrub(line, ["super-secret-value123"])
      assert scrubbed == "TOKEN=[REDACTED] leaked [REDACTED]"
    end

    test "skips short literals to avoid clobbering legit substrings" do
      line = "abc xyz abc"
      assert Scrubber.scrub(line, ["abc"]) == line
    end

    test "ignores non-string literals" do
      line = "ok"
      assert Scrubber.scrub(line, [nil, :atom, 12_345]) == line
    end
  end

  describe "wrap/2" do
    test "scrubs every binary line in a stream" do
      aws_key = "AKIA" <> String.duplicate("Z", 16)

      stream =
        Stream.map(
          [
            "first line ok",
            "#{aws_key} second",
            123_456,
            "third"
          ],
          & &1
        )

      result = stream |> Scrubber.wrap() |> Enum.to_list()

      assert result == ["first line ok", "[REDACTED] second", 123_456, "third"]
    end
  end

  test "scrub/2 leaves non-binary input alone" do
    assert Scrubber.scrub(123) == 123
    assert Scrubber.scrub(:atom) == :atom
  end

  test "placeholder/0 returns the marker used in scrubbed output" do
    assert Scrubber.placeholder() == "[REDACTED]"
  end
end
