defmodule SymphonyElixirWeb.ReposLive do
  @moduledoc """
  Per-repo health: running count, retrying count, and last successful run timestamp.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.Config
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @impl true
  def mount(_params, _session, socket) do
    socket = assign(socket, :payload, load_payload())

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
        <h1 class="page-title">Repos</h1>
        <p class="page-copy">Per-repository health: running sessions, retry queue, and last seen activity.</p>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <p><strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %></p>
        </section>
      <% else %>
        <%= if @payload.repos == [] do %>
          <p class="empty-state">No repositories configured.</p>
        <% else %>
          <div class="table-wrap">
            <table class="data-table">
              <thead>
                <tr>
                  <th>Repo</th>
                  <th>Running</th>
                  <th>Retrying</th>
                  <th>Last activity</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={repo <- @payload.repos}>
                  <td><span class="issue-id"><%= repo.key %></span></td>
                  <td><%= repo.running_count %></td>
                  <td><%= repo.retrying_count %></td>
                  <td class="mono"><%= repo.last_activity || "n/a" %></td>
                  <td>
                    <span class={health_class(repo)}>
                      <%= health_label(repo) %>
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
    base = Presenter.state_payload(orchestrator(), snapshot_timeout_ms())

    if base[:error] do
      base
    else
      repos = build_repo_health(base)
      Map.put(base, :repos, repos)
    end
  end

  defp build_repo_health(payload) do
    configured_repos = repo_keys()

    running_by_repo =
      payload.running
      |> Enum.group_by(&repo_key_from_workspace/1)
      |> Enum.reduce(%{}, fn {key, entries}, acc ->
        Map.put(acc, key, length(entries))
      end)

    retrying_by_repo =
      payload.retrying
      |> Enum.group_by(&repo_key_from_workspace/1)
      |> Enum.reduce(%{}, fn {key, entries}, acc ->
        Map.put(acc, key, length(entries))
      end)

    last_activity_by_repo =
      payload.running
      |> Enum.flat_map(fn entry ->
        case {repo_key_from_workspace(entry), entry.last_event_at} do
          {key, at} when is_binary(key) and is_binary(at) -> [{key, at}]
          _ -> []
        end
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {key, times} -> {key, Enum.max(times)} end)
      |> Map.new()

    all_keys =
      (configured_repos ++ Map.keys(running_by_repo) ++ Map.keys(retrying_by_repo))
      |> Enum.uniq()

    Enum.map(all_keys, fn key ->
      %{
        key: key,
        running_count: Map.get(running_by_repo, key, 0),
        retrying_count: Map.get(retrying_by_repo, key, 0),
        last_activity: Map.get(last_activity_by_repo, key)
      }
    end)
    |> Enum.sort_by(& &1.key)
  end

  defp repo_key_from_workspace(entry) do
    case Map.get(entry, :workspace_path) do
      path when is_binary(path) and path != "" ->
        Path.basename(path)

      _ ->
        "unknown"
    end
  end

  defp repo_keys do
    try do
      Config.settings!().repos |> Map.keys()
    rescue
      _ -> []
    end
  end

  defp health_label(%{running_count: r}) when r > 0, do: "active"
  defp health_label(%{retrying_count: r}) when r > 0, do: "retrying"
  defp health_label(_), do: "idle"

  defp health_class(%{running_count: r}) when r > 0, do: "state-badge state-badge-active"
  defp health_class(%{retrying_count: r}) when r > 0, do: "state-badge state-badge-warning"
  defp health_class(_), do: "state-badge"

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
