defmodule SymphonyElixir.Monday.Adapter do
  @moduledoc """
  Monday.com Tracker primitive. Owns all Monday writes per Spec 1 DL-005.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Monday.{Client, Item, PHIDetector}

  @items_page_query """
  query SymphonyItemsPage($boardId: ID!, $columnIds: [String!], $statusColumnId: ID!, $states: CompareValue!) {
    boards(ids: [$boardId]) {
      items_page(
        limit: 100,
        query_params: {
          rules: [{column_id: $statusColumnId, compare_value: $states, operator: any_of}],
          operator: and
        }
      ) {
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
          updates(limit: 25) {
            id
            body
            created_at
          }
        }
      }
    }
  }
  """

  @items_by_ids_query """
  query SymphonyItemsByIds($itemIds: [ID!], $columnIds: [String!]) {
    items(ids: $itemIds) {
      id
      name
      url
      created_at
      updated_at
      column_values(ids: $columnIds) {
        id
        text
      }
      updates(limit: 25) {
        id
        body
        created_at
      }
    }
  }
  """

  @status_labels_query """
  query SymphonyStatusLabels($boardId: ID!, $columnIds: [String!]) {
    boards(ids: [$boardId]) {
      columns(ids: $columnIds) {
        id
        settings_str
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
  @status_label_cache_ttl_ms :timer.minutes(5)

  # Cap a single failure update body to 8 KiB to stay well under Monday's
  # update size ceiling and to keep the dashboard view readable. Anything
  # larger gets a literal "[truncated]" suffix per the spec.
  @failure_body_max_bytes 8 * 1024
  @failure_truncation_suffix "[truncated]"

  @impl true
  def fetch_candidate_issues do
    cfg = tracker_config()
    eligible_states = cfg.active_states ++ cfg.handoff_states
    fetch_issues_filtered(cfg, eligible_states)
  end

  @impl true
  def fetch_issues_by_states(states), do: fetch_issues_filtered(tracker_config(), states)

  @impl true
  def fetch_issue_states_by_ids(ids) when is_list(ids) do
    item_ids = Enum.filter(ids, &is_binary/1)

    if item_ids == [] do
      {:ok, []}
    else
      cfg = tracker_config()
      column_ids = collect_column_ids(cfg)

      case client_module().graphql(@items_by_ids_query, %{"itemIds" => item_ids, "columnIds" => column_ids}, []) do
        {:ok, %{"data" => %{"items" => raw_items}}} ->
          normalize_items(raw_items, cfg, :all)

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_response, other}}
      end
    end
  end

  def fetch_issue_states_by_ids(_ids), do: {:ok, []}

  defp fetch_issues_filtered(cfg, allowed_states) do
    column_ids = collect_column_ids(cfg)

    cond do
      allowed_states == [] ->
        {:ok, []}

      true ->
        case translate_states_to_ids(cfg, allowed_states) do
          {:ok, []} ->
            {:ok, []}

          {:ok, state_ids} ->
            variables = %{
              "boardId" => cfg.board_id,
              "columnIds" => column_ids,
              "statusColumnId" => cfg.symphony_status_column_id,
              "states" => state_ids
            }

            case client_module().graphql(@items_page_query, variables, []) do
              {:ok, %{"data" => %{"boards" => [%{"items_page" => %{"items" => raw_items}}]}}} ->
                normalize_items(raw_items, cfg, allowed_states)

              {:error, _} = err ->
                err

              other ->
                {:error, {:unexpected_response, other}}
            end

          {:error, _} = err ->
            err
        end
    end
  end

  @doc false
  @spec translate_states_to_ids(map(), [String.t()]) ::
          {:ok, [non_neg_integer()]} | {:error, term()}
  def translate_states_to_ids(cfg, allowed_states) do
    case status_label_id_map(cfg) do
      {:ok, label_map} ->
        {known, unknown} =
          Enum.split_with(allowed_states, fn name -> Map.has_key?(label_map, name) end)

        case unknown do
          [] ->
            ids = Enum.map(known, fn name -> Map.fetch!(label_map, name) end)
            {:ok, ids}

          missing ->
            Logger.error(
              "Monday status labels not found on column #{inspect(cfg.symphony_status_column_id)}: " <>
                inspect(missing) <> "; refusing to run partial items_page filter"
            )

            {:error, {:unknown_monday_status_labels, cfg.symphony_status_column_id, missing}}
        end

      {:error, reason} = err ->
        Logger.error(
          "Failed to fetch Monday status label IDs for column " <>
            inspect(cfg.symphony_status_column_id) <> ": #{inspect(reason)}"
        )

        err
    end
  end

  defp status_label_id_map(cfg) do
    cache_key = {__MODULE__, :status_label_id_map, cfg.board_id, cfg.symphony_status_column_id}

    case Process.get(cache_key) do
      %{fetched_at_ms: fetched_at_ms, labels: map}
      when is_integer(fetched_at_ms) and is_map(map) ->
        if status_label_cache_fresh?(fetched_at_ms) do
          {:ok, map}
        else
          fetch_and_cache_status_label_id_map(cfg, cache_key)
        end

      _ ->
        fetch_and_cache_status_label_id_map(cfg, cache_key)
    end
  end

  defp fetch_and_cache_status_label_id_map(cfg, cache_key) do
    case fetch_status_label_id_map(cfg) do
      {:ok, map} when map_size(map) > 0 ->
        Process.put(cache_key, %{fetched_at_ms: monotonic_ms(), labels: map})
        {:ok, map}

      {:ok, _empty} = ok ->
        ok

      {:error, _} = err ->
        err
    end
  end

  defp status_label_cache_fresh?(fetched_at_ms) do
    monotonic_ms() - fetched_at_ms < @status_label_cache_ttl_ms
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp fetch_status_label_id_map(cfg) do
    variables = %{
      "boardId" => cfg.board_id,
      "columnIds" => [cfg.symphony_status_column_id]
    }

    case client_module().graphql(@status_labels_query, variables, []) do
      {:ok, %{"data" => %{"boards" => [%{"columns" => columns}]}}} ->
        case Enum.find(columns, &(Map.get(&1, "id") == cfg.symphony_status_column_id)) do
          %{"settings_str" => settings_str} -> parse_status_labels(settings_str)
          _ -> {:error, :status_column_not_found}
        end

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  defp parse_status_labels(settings_str) when is_binary(settings_str) do
    with {:ok, parsed} when is_map(parsed) <- Jason.decode(settings_str),
         %{"labels" => labels} when is_map(labels) <- parsed do
      deactivated = deactivated_status_label_ids(parsed)

      map =
        labels
        |> Enum.reduce(%{}, fn {id_str, name}, acc ->
          id_str = to_string(id_str)

          if MapSet.member?(deactivated, id_str) or not is_binary(name) do
            acc
          else
            case Integer.parse(id_str) do
              {id, ""} -> Map.put(acc, name, id)
              _ -> acc
            end
          end
        end)

      {:ok, map}
    else
      _ -> {:error, :invalid_settings_str}
    end
  end

  defp parse_status_labels(_), do: {:error, :invalid_settings_str}

  defp deactivated_status_label_ids(%{"deactivated_labels" => deactivated}) when is_list(deactivated) do
    deactivated
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp deactivated_status_label_ids(_parsed), do: MapSet.new()

  defp collect_column_ids(cfg) do
    [
      cfg.symphony_status_column_id,
      cfg.priority_column_id,
      cfg.description_column_id,
      cfg.branch_column_id,
      cfg.labels_column_id,
      cfg[:profile_column_id],
      cfg[:repo_column_id]
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc false
  @spec fetch_repo_label_set() :: {:ok, MapSet.t(String.t())} | {:error, term()}
  def fetch_repo_label_set do
    cfg = tracker_config()

    case cfg[:repo_column_id] do
      nil ->
        {:ok, MapSet.new()}

      column_id ->
        variables = %{"boardId" => cfg.board_id, "columnIds" => [column_id]}

        case client_module().graphql(@status_labels_query, variables, []) do
          {:ok, %{"data" => %{"boards" => [%{"columns" => columns}]}}} ->
            case Enum.find(columns, &(Map.get(&1, "id") == column_id)) do
              %{"settings_str" => settings_str} ->
                case parse_status_labels(settings_str) do
                  {:ok, label_map} -> {:ok, MapSet.new(Map.keys(label_map))}
                  {:error, _} = err -> err
                end

              _ ->
                {:error, :repo_column_not_found}
            end

          {:error, _} = err ->
            err

          other ->
            {:error, {:unexpected_response, other}}
        end
    end
  end

  defp normalize_items(raw_items, cfg, allowed_states) do
    raw_items
    |> Enum.reduce_while([], fn raw_item, acc ->
      case Item.from_monday(raw_item, cfg) do
        {:ok, item} ->
          if item_allowed?(item, allowed_states) do
            {:cont, [item | acc]}
          else
            {:cont, acc}
          end

        {:error, {:phi_detected, _findings}} ->
          {:halt, {:error, {:phi_detected, Map.get(raw_item, "id")}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = err -> err
      items -> {:ok, Enum.reverse(items)}
    end
  end

  defp item_allowed?(_item, :all), do: true

  defp item_allowed?(item, allowed_states) do
    item.state in allowed_states
  end

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
    safe_body = sanitize_failure_body(body || "")
    full_body = "#{@failure_marker}\n#{safe_body}"
    capped = cap_failure_body(full_body)

    case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => capped}, []) do
      {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  # Defense in depth: scrub PHI before posting any failure body, in case a
  # call site forgets to scrub stderr or includes a copied-in error string.
  # Per Spec 4 §2.5 / SYM-11923123790 AC5: NEVER post the raw body.
  defp sanitize_failure_body(body) when is_binary(body) do
    body
    |> redact_phi()
    |> redact_secret_fragments()
    |> redact_home_paths()
  end

  defp sanitize_failure_body(_), do: ""

  defp redact_phi(body) when is_binary(body) do
    case PHIDetector.scan(body) do
      :clean ->
        body

      {:phi, findings} ->
        Enum.reduce(findings, body, fn {_kind, match}, acc ->
          if is_binary(match) and match != "" do
            String.replace(acc, match, "[REDACTED-PHI]")
          else
            acc
          end
        end)
    end
  end

  defp redact_phi(_), do: ""

  defp redact_secret_fragments(body) when is_binary(body) do
    body =
      Regex.replace(
        ~r/\b(Bearer\s+)[A-Za-z0-9._~+\/=-]{12,}/i,
        body,
        fn _full, prefix -> prefix <> "[REDACTED-SECRET]" end
      )

    body =
      Regex.replace(
        ~r/\b([A-Za-z_][A-Za-z0-9_]*(?:TOKEN|API[_-]?KEY|SECRET|PASSWORD|PASS)[A-Za-z0-9_]*\s*[:=]\s*)[^\s,;&]+/i,
        body,
        fn _full, prefix -> prefix <> "[REDACTED-SECRET]" end
      )

    Regex.replace(
      ~r/\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,}|xox[baprs]-[A-Za-z0-9-]{16,})\b/,
      body,
      "[REDACTED-SECRET]"
    )
  end

  defp redact_home_paths(body) when is_binary(body) do
    Regex.replace(
      ~r{(?<![A-Za-z0-9._-])/(?:home|Users)/[^/\s:]+(?:/[^\s]*)?},
      body,
      "[REDACTED-HOME-PATH]"
    )
  end

  defp cap_failure_body(body) when is_binary(body) do
    cond do
      byte_size(body) <= @failure_body_max_bytes ->
        body

      byte_size(@failure_truncation_suffix) >= @failure_body_max_bytes ->
        # Defensive: if anyone ever shrinks the cap below the suffix length,
        # just emit the suffix rather than producing an invalid binary slice.
        @failure_truncation_suffix

      true ->
        budget = @failure_body_max_bytes - byte_size(@failure_truncation_suffix)
        utf8_prefix(body, budget) <> @failure_truncation_suffix
    end
  end

  defp utf8_prefix(body, max_bytes) when byte_size(body) <= max_bytes, do: body

  defp utf8_prefix(body, max_bytes)
       when is_binary(body) and is_integer(max_bytes) and max_bytes > 0 do
    do_utf8_prefix(body, max_bytes, [])
  end

  defp utf8_prefix(_body, _max_bytes), do: ""

  defp do_utf8_prefix(<<>>, _remaining, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_utf8_prefix(_body, remaining, acc) when remaining <= 0,
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_utf8_prefix(<<char::utf8, rest::binary>>, remaining, acc) do
    encoded = <<char::utf8>>
    size = byte_size(encoded)

    if size <= remaining do
      do_utf8_prefix(rest, remaining - size, [encoded | acc])
    else
      acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp do_utf8_prefix(<<_invalid_byte, rest::binary>>, remaining, acc) do
    do_utf8_prefix(rest, remaining, acc)
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

      {:ok, %{"id" => update_id, "body" => existing_body}} ->
        case heartbeat_acquire_decision(existing_body, instance_id, cfg.heartbeat_ttl_ms) do
          :refresh ->
            edit_existing_update(update_id, full_body)

          {:conflict, other_instance_id, timestamp} ->
            {:error, {:lock_held_by_other, other_instance_id, timestamp}}
        end

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
      {:ok, nil} ->
        :ok

      {:ok, %{"id" => update_id, "body" => existing_body}} ->
        if heartbeat_releasable?(existing_body, instance_id()) do
          edit_existing_update(update_id, "#{@heartbeat_marker}\n\nreleased\n")
        else
          :ok
        end

      {:error, _} = err ->
        err
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
          {:phi, _findings} -> {:error, :phi_in_description}
        end

      {:phi, _findings} ->
        {:error, :phi_in_title}
    end
  end

  defp upsert_marked_update(item_id, marker, body) do
    case find_update_by_marker(item_id, marker) do
      {:ok, nil} -> create_marked_update(item_id, body)
      {:ok, %{"id" => update_id}} -> edit_existing_update(update_id, body)
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
          [single] -> {:ok, single}
          _multiple -> {:error, :ambiguous}
        end

      {:ok, %{"data" => %{"items" => []}}} ->
        {:error, :sentinel_missing}

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

  defp heartbeat_acquire_decision(existing_body, current_instance_id, ttl_ms) do
    heartbeat = parse_heartbeat(existing_body)

    cond do
      heartbeat.released? ->
        :refresh

      heartbeat.instance_id in [nil, ""] ->
        :refresh

      heartbeat.instance_id == current_instance_id ->
        :refresh

      heartbeat_fresh?(heartbeat.timestamp, ttl_ms) ->
        {:conflict, heartbeat.instance_id, DateTime.to_iso8601(heartbeat.timestamp)}

      true ->
        :refresh
    end
  end

  defp heartbeat_releasable?(existing_body, current_instance_id) do
    heartbeat = parse_heartbeat(existing_body)

    heartbeat.instance_id in [nil, "", current_instance_id]
  end

  defp heartbeat_fresh?(%DateTime{} = timestamp, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    DateTime.diff(DateTime.utc_now(), timestamp, :millisecond) < ttl_ms
  end

  defp heartbeat_fresh?(_timestamp, _ttl_ms), do: false

  defp parse_heartbeat(body) when is_binary(body) do
    %{
      released?: String.contains?(body, "released"),
      instance_id: heartbeat_field(body, "instance_id"),
      timestamp: parse_heartbeat_timestamp(heartbeat_field(body, "timestamp"))
    }
  end

  defp parse_heartbeat(_body), do: %{released?: false, instance_id: nil, timestamp: nil}

  defp heartbeat_field(body, field_name) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [^field_name, value] -> String.trim(value)
        _ -> nil
      end
    end)
  end

  defp parse_heartbeat_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, _offset} -> timestamp
      _ -> nil
    end
  end

  defp parse_heartbeat_timestamp(_value), do: nil

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
