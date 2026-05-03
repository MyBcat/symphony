defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Scaffold for client-side tool calls requested by Codex app-server turns.
  Per Spec 1 DL-005, tracker write tools are not registered in agent
  sessions; Symphony's Tracker primitive (`SymphonyElixir.Monday.Adapter`)
  owns all Monday writes.
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
