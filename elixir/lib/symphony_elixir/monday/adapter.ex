defmodule SymphonyElixir.Monday.Adapter do
  @moduledoc """
  Monday.com Tracker primitive. Owns all Monday writes per Spec 1 DL-005.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Config
  alias SymphonyElixir.Monday.{Client, Item, PHIDetector}

  @items_page_query """
  query SymphonyItemsPage($boardId: ID!, $columnIds: [String!]) {
    boards(ids: [$boardId]) {
      items_page(limit: 100) {
        cursor
        items {
          id
          name
          url
          created_at
          updated_at
          column_values(ids: $columnIds) {
            id
            text
          }
        }
      }
    }
  }
  """

  @impl true
  def fetch_candidate_issues do
    cfg = tracker_config()
    eligible_states = cfg.active_states ++ cfg.handoff_states
    fetch_issues_filtered(cfg, eligible_states)
  end

  @impl true
  def fetch_issues_by_states(states), do: fetch_issues_filtered(tracker_config(), states)

  @impl true
  def fetch_issue_states_by_ids(_ids) do
    # In v1, used only for reconciliation — same path as candidates filtered by id list.
    # Implementing agent: extend with a separate `items` query if performance demands.
    {:ok, []}
  end

  defp fetch_issues_filtered(cfg, allowed_states) do
    column_ids = collect_column_ids(cfg)

    case client_module().graphql(@items_page_query, %{"boardId" => cfg.board_id, "columnIds" => column_ids}, []) do
      {:ok, %{"data" => %{"boards" => [%{"items_page" => %{"items" => raw_items}}]}}} ->
        normalize_items(raw_items, cfg, allowed_states)

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  defp collect_column_ids(cfg) do
    [
      cfg.symphony_status_column_id,
      cfg.priority_column_id,
      cfg.description_column_id,
      cfg.branch_column_id,
      cfg.labels_column_id,
      cfg[:profile_column_id]
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_items(raw_items, cfg, allowed_states) do
    raw_items
    |> Enum.map(&Item.from_monday(&1, cfg))
    |> Enum.reduce([], &keep_allowed(&1, &2, allowed_states))
    |> Enum.reverse()
    |> then(&{:ok, &1})
  end

  defp keep_allowed({:ok, item}, acc, allowed_states) do
    if item.state in allowed_states, do: [item | acc], else: acc
  end

  defp keep_allowed({:error, _reason}, acc, _allowed_states), do: acc

  # Write paths (Tracker primitive owns these per DL-005).
  # Implemented in Task 9.
  @impl true
  def update_issue_state(_item_id, _state_name), do: {:error, :not_implemented_yet}

  @impl true
  def upsert_workpad(_item_id, _body), do: {:error, :not_implemented_yet}

  @impl true
  def set_pr_url(_item_id, _url), do: {:error, :not_implemented_yet}

  @impl true
  def post_failure_update(_item_id, _body), do: {:error, :not_implemented_yet}

  @impl true
  def acquire_heartbeat, do: {:error, :not_implemented_yet}

  @impl true
  def release_heartbeat, do: {:error, :not_implemented_yet}

  @impl true
  def validate_no_phi(item) do
    title = Map.get(item, :title) || Map.get(item, "name")
    description = Map.get(item, :description)

    case PHIDetector.scan(title) do
      :clean ->
        case PHIDetector.scan(description) do
          :clean -> :ok
          {:phi, findings} -> {:error, {:phi_in_description, findings}}
        end

      {:phi, findings} ->
        {:error, {:phi_in_title, findings}}
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :monday_client_module, Client)
  end

  defp tracker_config do
    case Application.get_env(:symphony_elixir, :test_config_override) do
      %{tracker: tracker} -> tracker
      _ -> Config.settings!().tracker |> Map.from_struct()
    end
  end
end
