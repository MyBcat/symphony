defmodule SymphonyElixir.AgentRuntime do
  @moduledoc """
  Behaviour for coding-agent runtime adapters. One adapter per supported CLI
  (Codex, Claude Code, Gemini). Adapters expose a uniform session lifecycle
  to AgentRunner; runtime-native token counters and sandbox vocabulary stay
  per-kind (no cross-runtime normalization, per Spec 2 DL-007).
  """

  @type session :: term()
  @type config :: map()
  @type token_map :: %{required(atom()) => non_neg_integer()}

  @callback start_session(workspace_path :: Path.t(), config()) ::
              {:ok, session()} | {:error, term()}

  @callback send_turn(session(), prompt :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback stream_events(session()) :: Enumerable.t()

  @callback stop_session(session()) :: :ok | {:error, term()}

  @callback runtime_native_tokens(session()) :: token_map()

  @callback passes_safety_floor?(config(), floor :: map()) :: boolean()
end
