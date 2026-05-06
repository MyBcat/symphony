defmodule SymphonyElixirWeb.AgentsLive do
  @moduledoc """
  Live agent list — id, repo, profile, age, turn count, tokens, last event.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="page-header">
        <h1 class="page-title">Live Agents</h1>
        <p class="page-copy">Active agent sessions with real-time token and turn tracking.</p>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <p><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <%= if @payload.running == [] do %>
          <p class="empty-state">No active agents.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Repo</th>
                  <th>Profile</th>
                  <th>Age / Turns</th>
                  <th>Tokens</th>
                  <th>Last Event</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.running}>
                  <td><span class="issue-id"><%= entry.issue_identifier %></span></td>
                  <td><%= repo_from_entry(entry) %></td>
                  <td><%= entry.profile || "—" %></td>
                  <td class="numeric"><%= format_age_and_turns(entry.started_at, entry.turn_count, @now) %></td>
                  <td class="numeric">
                    <div class="token-stack">
                      <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                      <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                    </div>
                  </td>
                  <td>
                    <span class="event-text" title={entry.last_message || to_string(entry.last_event || "n/a")}>
                      <%= entry.last_message || to_string(entry.last_event || "n/a") %>
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  defp repo_from_entry(entry) do
    cond do
      is_binary(Map.get(entry, :repo)) and entry.repo != "" ->
        entry.repo |> String.slice(0, 30)

      is_binary(Map.get(entry, :workspace_path)) and entry.workspace_path != "" ->
        entry.workspace_path |> Path.basename() |> String.slice(0, 30)

      true ->
        "n/a"
    end
  end

  defp format_age_and_turns(started_at, turn_count, now) do
    secs = runtime_seconds(started_at, now)
    mins = div(secs, 60)
    s = rem(secs, 60)
    age = "#{mins}m #{s}s"

    if is_integer(turn_count) and turn_count > 0 do
      "#{age} / #{turn_count}"
    else
      age
    end
  end

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(DateTime.diff(now, started_at, :second), 0)
  end

  defp runtime_seconds(started_at, now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _} -> runtime_seconds(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_), do: "n/a"

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end
end
