import Config

# Do not start the Orchestrator at application boot in tests; each
# orchestrator_test.exs test starts its own instance with proper setup.
# The real WORKFLOW.md has api_token: $MONDAY_API_TOKEN (unresolved) which
# would cause the Monday heartbeat acquire to fail in CI.
config :symphony_elixir, :start_orchestrator, false
