defmodule SymphonyElixir.Codex.DynamicToolTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.DynamicTool

  test "tool_specs returns empty list (linear_graphql removed; no replacement)" do
    assert DynamicTool.tool_specs() == []
  end

  test "execute on any tool name returns unsupported response" do
    response = DynamicTool.execute("linear_graphql", %{}, [])
    assert response["success"] == false
    decoded = Jason.decode!(response["output"])
    assert decoded["error"]["supportedTools"] == []
  end
end
