defmodule SymphonyElixir.HttpServer do
  @moduledoc """
  Compatibility facade that starts the Phoenix observability endpoint when enabled.
  """

  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @secret_key_bytes 48

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(opts \\ []) do
    case Keyword.get(opts, :port, Config.server_port()) do
      port when is_integer(port) and port >= 0 ->
        orchestrator = Keyword.get(opts, :orchestrator, Orchestrator)
        snapshot_timeout_ms = Keyword.get(opts, :snapshot_timeout_ms, 15_000)

        # Localhost binding is hard-coded per HIPAA constraint — agent stderr must
        # never be exposed externally via the dashboard.
        config_host =
          try do
            Config.settings!().server.host
          rescue
            _ -> nil
          end

        effective_host = Keyword.get(opts, :host) || config_host

        if effective_host in ["0.0.0.0", "[::]", "::"] do
          raise RuntimeError,
                "Symphony dashboard MUST NOT bind to #{effective_host} (HIPAA — agent stderr can leak via dashboard if exposed). " <>
                  "Localhost binding is non-negotiable."
        end

        ip = {127, 0, 0, 1}

        endpoint_opts = [
          server: true,
          http: [ip: ip, port: port],
          url: [host: "127.0.0.1"],
          orchestrator: orchestrator,
          snapshot_timeout_ms: snapshot_timeout_ms,
          secret_key_base: secret_key_base()
        ]

        endpoint_config =
          :symphony_elixir
          |> Application.get_env(Endpoint, [])
          |> Keyword.merge(endpoint_opts)

        Application.put_env(:symphony_elixir, Endpoint, endpoint_config)
        Endpoint.start_link()

      _ ->
        :ignore
    end
  end

  @spec bound_port(term()) :: non_neg_integer() | nil
  def bound_port(_server \\ __MODULE__) do
    case Bandit.PhoenixAdapter.server_info(Endpoint, :http) do
      {:ok, {_ip, port}} when is_integer(port) -> port
      _ -> nil
    end
  rescue
    _error -> nil
  catch
    :exit, _reason -> nil
  end

  defp secret_key_base do
    Base.encode64(:crypto.strong_rand_bytes(@secret_key_bytes), padding: false)
  end
end
