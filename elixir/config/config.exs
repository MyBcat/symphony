import Config

if config_env() == :test do
  import_config "test.exs"
end

config :phoenix, :json_library, Jason

config :symphony_elixir, SymphonyElixirWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: SymphonyElixirWeb.ErrorHTML, json: SymphonyElixirWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SymphonyElixir.PubSub,
  live_view: [signing_salt: "symphony-live-view"],
  secret_key_base: String.duplicate("s", 64),
  check_origin: false,
  server: false

if config_env() == :test do
  # Use the in-memory tracker so the Application-supervised Orchestrator does
  # not attempt a real Monday API call when acquiring its heartbeat lock on boot.
  config :symphony_elixir, :tracker_adapter_override, SymphonyElixir.Tracker.MemoryMonday
end
