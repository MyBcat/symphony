defmodule SymphonyElixir.Monday.PRDetectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.PRDetector

  test "detects standard GitHub PR URL" do
    text = "Opened PR: https://github.com/openai/symphony/pull/123"
    assert {:ok, "https://github.com/openai/symphony/pull/123"} = PRDetector.scan(text)
  end

  test "ignores GitHub issue URLs" do
    text = "Filed issue: https://github.com/openai/symphony/issues/123"
    assert :no_match = PRDetector.scan(text)
  end

  test "ignores GitHub gist URLs" do
    text = "Created gist: https://gist.github.com/foo/bar"
    assert :no_match = PRDetector.scan(text)
  end

  test "returns first match when multiple PRs are mentioned" do
    text = "Created https://github.com/x/y/pull/1 and https://github.com/x/y/pull/2"
    assert {:ok, "https://github.com/x/y/pull/1"} = PRDetector.scan(text)
  end

  test "returns :no_match on plain prose" do
    assert PRDetector.scan("Working on the implementation now.") == :no_match
  end
end
