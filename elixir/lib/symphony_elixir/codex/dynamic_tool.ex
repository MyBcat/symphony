defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Scaffold for client-side tool calls requested by Codex app-server turns.
  Per Spec 1 DL-005, the previous `linear_graphql` tool is removed and not
  replaced — agents have no Monday access; Symphony's Tracker primitive
  (`SymphonyElixir.Monday.Adapter`) owns all Monday writes.
  """

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, _arguments, _opts) do
    %{
      "success" => false,
      "output" => Jason.encode!(%{"error" => %{"message" => "Unsupported dynamic tool: #{inspect(tool)}.", "supportedTools" => []}}, pretty: true),
      "contentItems" => [
        %{"type" => "inputText", "text" => "No client-side tools are registered."}
      ]
    }
  end

  @spec tool_specs() :: [map()]
  def tool_specs, do: []
end
