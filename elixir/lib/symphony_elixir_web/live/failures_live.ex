defmodule SymphonyElixirWeb.FailuresLive do
  @moduledoc """
  Failure log — last 50 failed/retrying sessions with timestamp, profile, exit code, error.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @max_failures 50
  @max_stderr_lines 20

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:max_failures, @max_failures)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply, assign(socket, :payload, load_payload())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="page-header">
        <h1 class="page-title">Failures</h1>
        <p class="page-copy">Last <%= @max_failures %> failed sessions. Retry queue shows agents waiting for next attempt.</p>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <p><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <%= if @payload.failures == [] do %>
          <p class="empty-state">No failures recorded.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr>
                  <th>ID</th>
                  <th>Attempt</th>
                  <th>Exit / Error</th>
                  <th>Next retry</th>
                  <th>Stderr / Detail</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={entry <- @payload.failures}>
                  <td><span class="issue-id"><%= entry.issue_identifier %></span></td>
                  <td><%= entry.attempt %></td>
                  <td><%= entry.exit_code %></td>
                  <td class="mono"><%= entry.due_at || "n/a" %></td>
                  <td>
                    <pre class="stderr-pre"><%= entry.stderr_tail %></pre>
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
    base = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

    if base[:error] do
      base
    else
      failures =
        base.retrying
        |> Enum.take(@max_failures)
        |> Enum.map(&build_failure_entry/1)

      Map.put(base, :failures, failures)
    end
  end

  defp build_failure_entry(entry) do
    error = entry.error || ""
    lines = error |> String.split("\n") |> Enum.take(-@max_stderr_lines) |> Enum.join("\n")
    exit_code = extract_exit_code(error)

    %{
      issue_identifier: entry.issue_identifier,
      attempt: entry.attempt,
      exit_code: exit_code,
      due_at: entry.due_at,
      stderr_tail: lines
    }
  end

  defp extract_exit_code(error) when is_binary(error) do
    case Regex.run(~r/exit[_ ](?:code[:\s]+)?(\d+)/i, error) do
      [_, code] -> "exit #{code}"
      _ -> "n/a"
    end
  end

  defp extract_exit_code(_), do: "n/a"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
