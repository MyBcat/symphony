defmodule SymphonyElixir.Monday.Adapter do
  @moduledoc """
  Monday.com Tracker primitive. Owns all Monday writes per Spec 1 DL-005.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Monday.{Client, Item, PHIDetector}

  @items_page_query """
  query SymphonyItemsPage($boardId: ID!, $columnIds: [String!], $statusColumnId: ID!, $states: CompareValue!, $limit: Int!) {
    boards(ids: [$boardId]) {
      items_page(
        limit: $limit,
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

  @create_item_mutation """
  mutation SymphonyCreateItem($boardId: ID!, $itemName: String!) {
    create_item(board_id: $boardId, item_name: $itemName, create_labels_if_missing: false) {
      id
      name
    }
  }
  """

  @delete_item_mutation """
  mutation SymphonyDeleteItem($itemId: ID!) {
    delete_item(item_id: $itemId) {
      id
    }
  }
  """

  @list_board_item_names_query """
  query SymphonyBoardItemNames($boardId: ID!, $limit: Int!) {
    boards(ids: [$boardId]) {
      items_page(limit: $limit) {
        cursor
        items {
          id
          name
        }
      }
    }
  }
  """

  @workpad_marker "## Symphony Workpad"
  @failure_marker "## Symphony Failures"
  @heartbeat_marker "## Symphony Heartbeat"
  @pr_refusal_marker "## Symphony PR Refusal"
  @phi_refusal_marker "## Symphony PHI Refusal"
  @codex_review_marker "## Symphony Codex Review"
  @auto_merge_failure_marker "## Symphony Auto-Merge Failed"
  @status_label_cache_ttl_ms :timer.minutes(5)

  # Cap a single failure update body to 8 KiB to stay well under Monday's
  # update size ceiling and to keep the dashboard view readable. Anything
  # larger gets a literal "[truncated]" suffix per the spec.
  @failure_body_max_bytes 8 * 1024
  @failure_truncation_suffix "[truncated]"

  @impl true
  def fetch_candidate_issues do
    case fetch_candidate_issues_with_phi_findings() do
      {:ok, %{items: items, phi_offenders: []}} ->
        {:ok, items}

      {:ok, %{phi_offenders: [first | _]}} ->
        # Spec 1 backward-compat: callers using the legacy contract see the
        # same `:phi_detected` error tuple they always have. Spec M-6 callers
        # use `fetch_candidate_issues_with_phi_findings/0` to learn about
        # *every* offender on the page so each one can be cancelled + refused
        # independently.
        {:error, {:phi_detected, first.id}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def fetch_candidate_issues_with_phi_findings, do: fetch_candidate_issues_with_phi_findings([])

  def fetch_candidate_issues_with_phi_findings(opts) do
    cfg = tracker_config()
    eligible_states = cfg.active_states ++ cfg.handoff_states

    fetch_issues_filtered_with_phi(
      cfg,
      eligible_states,
      phi_gate_mode(),
      Keyword.get(opts, :limit, 100)
    )
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
          mode = phi_gate_mode()

          case normalize_items_with_phi(raw_items, cfg, :all, mode) do
            {:ok, %{items: items, phi_offenders: []}} ->
              {:ok, items}

            {:ok, %{items: items, phi_offenders: offenders}} when mode == :warn ->
              Enum.each(offenders, &log_warn_refresh_offender/1)
              {:ok, items}

            {:ok, %{phi_offenders: [first | _]}} ->
              {:error, {:phi_detected, first}}

            {:error, _} = err ->
              err
          end

        {:error, _} = err ->
          err

        other ->
          {:error, {:unexpected_response, other}}
      end
    end
  end

  def fetch_issue_states_by_ids(_ids), do: {:ok, []}

  defp fetch_issues_filtered(cfg, allowed_states) do
    do_fetch_issues_page(cfg, allowed_states, 100, fn raw_items ->
      normalize_items(raw_items, cfg, allowed_states)
    end)
  end

  defp fetch_issues_filtered_with_phi(cfg, allowed_states, mode, limit) do
    do_fetch_issues_page(cfg, allowed_states, limit, fn raw_items ->
      normalize_items_with_phi(raw_items, cfg, allowed_states, mode)
    end)
  end

  defp do_fetch_issues_page(cfg, allowed_states, limit, normalize_fn) do
    column_ids = collect_column_ids(cfg)

    cond do
      allowed_states == [] ->
        normalize_fn.([])

      true ->
        case translate_states_to_ids(cfg, allowed_states) do
          {:ok, []} ->
            normalize_fn.([])

          {:ok, state_ids} ->
            variables = %{
              "boardId" => cfg.board_id,
              "columnIds" => column_ids,
              "statusColumnId" => cfg.symphony_status_column_id,
              "states" => state_ids,
              "limit" => limit
            }

            case client_module().graphql(@items_page_query, variables, []) do
              {:ok, %{"data" => %{"boards" => [%{"items_page" => %{"items" => raw_items}}]}}} ->
                normalize_fn.(raw_items)

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
            Logger.error("Monday status labels not found on column #{inspect(cfg.symphony_status_column_id)}: " <> inspect(missing) <> "; refusing to run partial items_page filter")

            {:error, {:unknown_monday_status_labels, cfg.symphony_status_column_id, missing}}
        end

      {:error, reason} = err ->
        Logger.error("Failed to fetch Monday status label IDs for column " <> inspect(cfg.symphony_status_column_id) <> ": #{inspect(reason)}")

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

        {:error, {:phi_detected, findings}} ->
          {:halt, {:error, {:phi_detected, build_phi_offender(raw_item, cfg, findings)}}}

        {:error, {:phi_detector_failed, field}} ->
          {:halt, {:error, {:phi_detector_failed, build_phi_detector_failure(raw_item, cfg, field)}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = err -> err
      items -> {:ok, Enum.reverse(items)}
    end
  end

  # PHI-aware normalize. Spec M-6 §AC1: a PHI finding must NOT halt the page;
  # the orchestrator is responsible for cancelling each offender and posting
  # a `## Symphony PHI Refusal` workpad. Other (non-PHI) errors still halt
  # because they indicate a genuine page-level fetch problem (missing column,
  # bad shape) that the orchestrator can't sanely partition.
  defp normalize_items_with_phi(raw_items, cfg, allowed_states, mode) do
    raw_items
    |> Enum.reduce_while({[], []}, fn raw_item, {items_acc, offenders_acc} ->
      case Item.from_monday(raw_item, cfg) do
        {:ok, item} ->
          if item_allowed?(item, allowed_states) do
            {:cont, {[item | items_acc], offenders_acc}}
          else
            {:cont, {items_acc, offenders_acc}}
          end

        {:error, {:phi_detected, findings}} ->
          offender = build_phi_offender(raw_item, cfg, findings)

          {:cont, maybe_include_phi_item(raw_item, cfg, allowed_states, mode, items_acc, [offender | offenders_acc])}

        {:error, {:phi_detector_failed, field}} ->
          offender = build_phi_detector_failure(raw_item, cfg, field)

          {:cont, maybe_include_phi_item(raw_item, cfg, allowed_states, mode, items_acc, [offender | offenders_acc])}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = err ->
        err

      {items, offenders} ->
        {:ok,
         %{
           items: Enum.reverse(items),
           phi_offenders: Enum.reverse(offenders)
         }}
    end
  end

  # Build a PHI offender record carrying ONLY finding kinds — never matched
  # text. Spec M-6 §Constraints: ZERO PHI may appear in logs, stdout, or
  # Workpad bodies.
  defp build_phi_offender(raw_item, cfg, findings) do
    raw_id = Map.get(raw_item, "id")
    item_id = if is_binary(raw_id), do: raw_id, else: to_string(raw_id || "")
    identifier = "#{cfg.identifier_prefix}-#{item_id}"

    kinds =
      findings
      |> List.wrap()
      |> Enum.map(fn
        {kind, _matched_text} when is_atom(kind) -> kind
        kind when is_atom(kind) -> kind
        _ -> :unknown
      end)
      |> Enum.uniq()

    %{id: item_id, identifier: identifier, kinds: kinds}
  end

  defp build_phi_detector_failure(raw_item, cfg, field) do
    build_phi_offender(raw_item, cfg, [detector_failure_kind(field)])
  end

  defp detector_failure_kind(:title), do: :detector_failed_title
  defp detector_failure_kind(:description), do: :detector_failed_description
  defp detector_failure_kind(_), do: :detector_failed

  defp maybe_include_phi_item(raw_item, cfg, allowed_states, :warn, items_acc, offenders_acc) do
    case Item.from_monday(raw_item, cfg, scan_phi?: false) do
      {:ok, item} ->
        if item_allowed?(item, allowed_states) do
          {[item | items_acc], offenders_acc}
        else
          {items_acc, offenders_acc}
        end

      {:error, _reason} ->
        {items_acc, offenders_acc}
    end
  end

  defp maybe_include_phi_item(_raw_item, _cfg, _allowed_states, _mode, items_acc, offenders_acc) do
    {items_acc, offenders_acc}
  end

  defp log_warn_refresh_offender(offender) do
    Logger.warning("Symphony PHI gate (warn mode) detected PHI during item refresh identifier=#{offender.identifier} kinds=#{inspect(offender.kinds)}; continuing")
  end

  defp phi_gate_mode do
    case Application.get_env(:symphony_elixir, :test_config_override) do
      %{phi_gate: %{mode: "warn"}} ->
        :warn

      _ ->
        case Config.settings() do
          {:ok, %SymphonyElixir.Config.Schema{phi_gate: %{mode: "warn"}}} -> :warn
          _ -> :strict
        end
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

  @impl true
  def post_pr_refusal(item_id, body) do
    safe_body = sanitize_failure_body(body || "")
    full_body = ensure_marker(safe_body, @pr_refusal_marker)
    capped = cap_failure_body(full_body)

    case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => capped}, []) do
      {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def post_codex_review(item_id, body) do
    # Spec 4 §2.8a — full Codex output is posted to the Workpad. Defense-in-
    # depth: scrub PHI / secrets before write. The Codex review prompt does
    # NOT include any PHI, but Codex's response could echo file paths or
    # token-shaped strings that the scrubber catches.
    safe_body = sanitize_failure_body(body || "")
    full_body = ensure_marker(safe_body, @codex_review_marker)
    capped = cap_failure_body(full_body)

    case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => capped}, []) do
      {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def post_auto_merge_failure(item_id, body) do
    safe_body = sanitize_failure_body(body || "")
    full_body = ensure_marker(safe_body, @auto_merge_failure_marker)
    capped = cap_failure_body(full_body)

    case client_module().graphql(@create_update, %{"itemId" => parse_item_id(item_id), "body" => capped}, []) do
      {:ok, %{"data" => %{"create_update" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @impl true
  def post_phi_refusal(item_id, body) do
    # `sanitize_failure_body/1` re-runs the PHI redactor. It is defensive only —
    # `Workpad.render_phi_refusal/2` already renders kinds-only and never sees
    # the raw matched text — but per Spec M-6 §Constraints "ZERO PHI may appear
    # ... EVER. Redaction is non-negotiable" we belt-and-suspender it.
    safe_body = sanitize_failure_body(body || "")
    full_body = ensure_marker(safe_body, @phi_refusal_marker)
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
    case safe_phi_scan(body) do
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

      {:error, :phi_detector_failed} ->
        "[REDACTED-PHI-SCAN-FAILED]"
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

  @doc """
  Create an item on a Monday board. Used by the e2e nightly harness
  (SYM-11923096576) to seed synthetic test items. Goes through the Adapter so
  the DL-005 "all Monday writes via Monday.Adapter" rule holds for harness
  fixtures the same way it does for orchestrator writes.
  """
  @spec create_item(integer() | String.t(), String.t()) ::
          {:ok, %{id: String.t(), name: String.t()}} | {:error, term()}
  def create_item(board_id, name) when is_binary(name) do
    vars = %{"boardId" => board_id, "itemName" => name}

    case client_module().graphql(@create_item_mutation, vars, []) do
      {:ok, %{"data" => %{"create_item" => %{"id" => id, "name" => returned_name}}}}
      when is_binary(id) ->
        {:ok, %{id: id, name: returned_name}}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Delete a Monday item by id. Used by the e2e nightly harness to tear down
  synthetic items at the end of the run; never invoked from the orchestrator's
  dispatch loop.
  """
  @spec delete_item(integer() | String.t()) :: :ok | {:error, term()}
  def delete_item(item_id) do
    vars = %{"itemId" => parse_item_id(item_id)}

    case client_module().graphql(@delete_item_mutation, vars, []) do
      {:ok, %{"data" => %{"delete_item" => %{"id" => _}}}} -> :ok
      {:error, _} = err -> err
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Return a flat list of `%{id, name}` items on the given board (limit = 50 by
  default). Used by the e2e harness's "non-synthetic count" guard: refuse to
  run if the sandbox board has more than N items not prefixed with the
  synthetic marker, since that means the operator pointed the harness at a
  non-sandbox board by mistake.
  """
  @spec list_board_items(integer() | String.t(), keyword()) ::
          {:ok, [%{id: String.t(), name: String.t()}]} | {:error, term()}
  def list_board_items(board_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    vars = %{"boardId" => board_id, "limit" => limit}

    case client_module().graphql(@list_board_item_names_query, vars, []) do
      {:ok, %{"data" => %{"boards" => [%{"items_page" => %{"items" => raw_items}}]}}} ->
        items =
          Enum.map(raw_items, fn raw ->
            %{
              id: to_string(Map.get(raw, "id", "")),
              name: Map.get(raw, "name") || ""
            }
          end)

        {:ok, items}

      {:ok, %{"data" => %{"boards" => []}}} ->
        {:error, :board_not_found}

      {:error, _} = err ->
        err

      other ->
        {:error, {:unexpected_response, other}}
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

    case safe_phi_scan(title) do
      :clean ->
        case safe_phi_scan(description) do
          :clean -> :ok
          {:phi, _findings} -> {:error, :phi_in_description}
          {:error, :phi_detector_failed} -> {:error, :phi_detector_failed_description}
        end

      {:phi, _findings} ->
        {:error, :phi_in_title}

      {:error, :phi_detector_failed} ->
        {:error, :phi_detector_failed_title}
    end
  end

  defp safe_phi_scan(text) do
    try do
      phi_detector().scan(text)
    catch
      _kind, _reason -> {:error, :phi_detector_failed}
    rescue
      _error -> {:error, :phi_detector_failed}
    end
  end

  defp phi_detector do
    Application.get_env(:symphony_elixir, :phi_detector_module, PHIDetector)
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
    token = mint_lock_token(instance_id)
    # Spec M-7 AC1: lock token = "<instance_id>::<random>". The `token:` line is
    # authoritative for ownership comparison; `instance_id:` and `timestamp:` are
    # kept for backward compatibility with bodies written by pre-M-7 instances
    # so an old leader's body still parses cleanly during a rolling upgrade.
    "token: #{token}\ninstance_id: #{instance_id}\ntimestamp: #{ts}\n"
  end

  defp mint_lock_token(instance_id) do
    nonce = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "#{instance_id}::#{nonce}"
  end

  defp heartbeat_acquire_decision(existing_body, current_instance_id, ttl_ms) do
    heartbeat = parse_heartbeat(existing_body)
    existing_owner = heartbeat_owner(heartbeat)

    cond do
      heartbeat.released? ->
        :refresh

      existing_owner in [nil, ""] ->
        :refresh

      existing_owner == current_instance_id ->
        :refresh

      heartbeat_fresh?(heartbeat.timestamp, ttl_ms) ->
        {:conflict, existing_owner, DateTime.to_iso8601(heartbeat.timestamp)}

      true ->
        :refresh
    end
  end

  defp heartbeat_releasable?(existing_body, current_instance_id) do
    heartbeat = parse_heartbeat(existing_body)

    heartbeat_owner(heartbeat) in [nil, "", current_instance_id]
  end

  # Owner of the lock = instance_id portion of the token if present, else the
  # legacy `instance_id:` field. This lets us recognize bodies written by
  # pre-M-7 instances during upgrade.
  defp heartbeat_owner(%{token: token}) when is_binary(token) and token != "" do
    case String.split(token, "::", parts: 2) do
      [owner | _] -> owner
      _ -> nil
    end
  end

  defp heartbeat_owner(%{instance_id: instance_id}), do: instance_id

  defp heartbeat_fresh?(%DateTime{} = timestamp, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    DateTime.diff(DateTime.utc_now(), timestamp, :millisecond) < ttl_ms
  end

  defp heartbeat_fresh?(_timestamp, _ttl_ms), do: false

  defp parse_heartbeat(body) when is_binary(body) do
    %{
      released?: String.contains?(body, "released"),
      token: heartbeat_field(body, "token"),
      instance_id: heartbeat_field(body, "instance_id"),
      timestamp: parse_heartbeat_timestamp(heartbeat_field(body, "timestamp"))
    }
  end

  defp parse_heartbeat(_body),
    do: %{released?: false, token: nil, instance_id: nil, timestamp: nil}

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
