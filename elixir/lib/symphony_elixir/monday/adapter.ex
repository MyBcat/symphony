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

  @change_simple_column_value """
  mutation SymphonyChangeSimple($itemId: ID!, $columnId: String!, $value: String!) {
    change_simple_column_value(item_id: $itemId, column_id: $columnId, value: $value) {
      id
    }
  }
  """

  @create_update """
  mutation SymphonyCreateUpdate($itemId: ID!, $body: String!) {
    create_update(item_id: $itemId, body: $body) {
      id
      body
    }
  }
  """

  @edit_update """
  mutation SymphonyEditUpdate($id: ID!, $body: String!) {
    edit_update(id: $id, body: $body) {
      id
    }
  }
  """

  @get_item_updates """
  query SymphonyGetItemUpdates($itemId: ID!) {
    items(ids: [$itemId]) {
      updates(limit: 25) {
        id
        body
      }
    }
  }
  """

  @workpad_marker "## Symphony Workpad"
  @failure_marker "## Symphony Failures"
  @heartbeat_marker "## Symphony Heartbeat"

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
  @impl true
  def update_issue_state(item_id, state_name) do
    cfg = tracker_config()
    vars = %{"itemId" => item_id, "columnId" => cfg.symphony_status_column_id, "value" => state_name}

    case client_module().graphql(@change_simple_column_value, vars, []) do
      {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def upsert_workpad(item_id, body) do
    full_body = ensure_marker(body, @workpad_marker)
    upsert_marked_update(item_id, @workpad_marker, full_body)
  end

  @impl true
  def set_pr_url(item_id, url) do
    cfg = tracker_config()

    case cfg[:pr_column_id] do
      nil ->
        {:error, :no_pr_column_configured}

      column_id ->
        vars = %{"itemId" => item_id, "columnId" => column_id, "value" => url}

        case client_module().graphql(@change_simple_column_value, vars, []) do
          {:ok, %{"data" => %{"change_simple_column_value" => %{"id" => _}}}} -> :ok
          {:error, _} = err -> err
          other -> {:error, {:unexpected_response, other}}
        end
    end
  end

  @impl true
  def post_failure_update(item_id, body) do
    full_body = "#{@failure_marker}\n\n#{body}"

    case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => full_body}, []) do
      {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def acquire_heartbeat do
    cfg = tracker_config()
    instance_id = instance_id()
    body = render_heartbeat_body(instance_id)
    full_body = "#{@heartbeat_marker}\n\n#{body}"

    case find_update_by_marker(cfg.heartbeat_item_id, @heartbeat_marker) do
      {:ok, nil} ->
        create_marked_update(cfg.heartbeat_item_id, full_body)

      {:ok, update_id} ->
        # v1 simple lock: existing heartbeat present → assume our own (single-instance assumption per Spec 1).
        # Future hardening (deferred): read body, parse instance_id + timestamp; if different instance AND fresh
        # within heartbeat_ttl_ms → return {:error, :lock_held_by_other}; else refresh.
        edit_existing_update(update_id, full_body)

      {:error, :ambiguous} ->
        {:error, :ambiguous_heartbeat}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def release_heartbeat do
    cfg = tracker_config()

    case find_update_by_marker(cfg.heartbeat_item_id, @heartbeat_marker) do
      {:ok, nil} -> :ok
      {:ok, update_id} -> edit_existing_update(update_id, "#{@heartbeat_marker}\n\nreleased\n")
      {:error, _} = err -> err
    end
  end

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

  defp upsert_marked_update(item_id, marker, body) do
    case find_update_by_marker(item_id, marker) do
      {:ok, nil} -> create_marked_update(item_id, body)
      {:ok, update_id} -> edit_existing_update(update_id, body)
      {:error, :ambiguous} -> {:error, :ambiguous_workpad}
      {:error, _} = err -> err
    end
  end

  defp find_update_by_marker(item_id, marker) do
    case client_module().graphql(@get_item_updates, %{"itemId" => parse_item_id(item_id)}, []) do
      {:ok, %{"data" => %{"items" => [%{"updates" => updates}]}}} ->
        matches = Enum.filter(updates, fn u -> String.starts_with?(u["body"] || "", marker) end)

        case matches do
          [] -> {:ok, nil}
          [single] -> {:ok, single["id"]}
          _multiple -> {:error, :ambiguous}
        end

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  defp create_marked_update(item_id, body) do
    case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => body}, []) do
      {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp edit_existing_update(update_id, body) do
    case client_module().graphql(@edit_update, %{"id" => update_id, "body" => body}, []) do
      {:ok, %{"data" => %{"edit_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  defp ensure_marker(body, marker) do
    if String.starts_with?(body || "", marker), do: body, else: "#{marker}\n\n#{body}"
  end

  defp parse_item_id(item_id) when is_integer(item_id), do: item_id

  defp parse_item_id(item_id) when is_binary(item_id) do
    case Integer.parse(item_id) do
      {int, ""} -> int
      _ -> item_id
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

  defp render_heartbeat_body(instance_id) do
    ts = DateTime.utc_now() |> DateTime.to_iso8601()
    "instance_id: #{instance_id}\ntimestamp: #{ts}\n"
  end

  defp instance_id do
    case Application.get_env(:symphony_elixir, :instance_id) do
      nil ->
        id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
        Application.put_env(:symphony_elixir, :instance_id, id)
        id

      id ->
        id
    end
  end
end
