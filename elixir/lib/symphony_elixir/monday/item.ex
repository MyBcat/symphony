defmodule SymphonyElixir.Monday.Item do
  @moduledoc """
  Normalize Monday item payloads into Symphony's issue model.

  Identifier scheme: `<config.identifier_prefix>-<item.id>` (per Spec 1 DL-004).

  PHI rejection: item title and description column are scanned via
  `SymphonyElixir.Monday.PHIDetector`; on hit, returns `{:error, {:phi_detected, findings}}`.
  Tech Board is a no-PHI surface per Spec 1 DL-011.
  """

  alias SymphonyElixir.Monday.PHIDetector
  alias SymphonyElixir.Tracker.Issue

  @type config :: %{
          identifier_prefix: String.t(),
          symphony_status_column_id: String.t(),
          priority_column_id: String.t() | nil,
          description_column_id: String.t() | nil,
          branch_column_id: String.t() | nil,
          labels_column_id: String.t() | nil,
          profile_column_id: String.t() | nil,
          repo_column_id: String.t() | nil
        }

  @type t :: Issue.t()

  @spec from_monday(map(), config()) ::
          {:ok, t()}
          | {:error, {:missing_column, String.t()} | {:phi_detected, [PHIDetector.finding()]}}
  def from_monday(raw, config) when is_map(raw) and is_map(config) do
    title = Map.get(raw, "name", "")
    description =
      column_text(raw, config[:description_column_id])
      |> ensure_blank()
      |> case do
        nil -> description_from_updates(raw)
        text -> text
      end

    with :clean <- PHIDetector.scan(title),
         :clean <- PHIDetector.scan(description),
         {:ok, state} <- require_column_text(raw, config.symphony_status_column_id) do
      identifier = "#{config.identifier_prefix}-#{raw["id"]}"

      item = %Issue{
        id: raw["id"],
        identifier: identifier,
        title: title,
        description: description,
        priority: priority_value(raw, config[:priority_column_id]),
        state: state,
        branch_name: branch_value(raw, config[:branch_column_id], identifier),
        url: Map.get(raw, "url"),
        labels: labels_value(raw, config[:labels_column_id]),
        profile: profile_value(raw, config[:profile_column_id]),
        repo: repo_value(raw, config[:repo_column_id]),
        blocked_by: [],
        created_at: parse_datetime(Map.get(raw, "created_at")),
        updated_at: parse_datetime(Map.get(raw, "updated_at"))
      }

      {:ok, item}
    else
      {:phi, findings} -> {:error, {:phi_detected, findings}}
      {:error, _} = err -> err
    end
  end

  defp require_column_text(raw, column_id) when is_binary(column_id) do
    case column_text(raw, column_id) do
      nil -> {:error, {:missing_column, column_id}}
      text -> {:ok, text}
    end
  end

  defp column_text(_raw, nil), do: nil

  defp column_text(raw, column_id) when is_binary(column_id) do
    raw
    |> Map.get("column_values", [])
    |> Enum.find_value(fn col ->
      if col["id"] == column_id, do: Map.get(col, "text"), else: nil
    end)
  end

  defp priority_value(raw, column_id) do
    case column_text(raw, column_id) do
      nil -> nil
      text -> priority_label_to_int(text)
    end
  end

  defp priority_label_to_int("High"), do: 1
  defp priority_label_to_int("Medium"), do: 2
  defp priority_label_to_int("Low"), do: 3
  defp priority_label_to_int(_), do: nil

  defp branch_value(_raw, nil, identifier_fallback), do: identifier_fallback

  defp branch_value(raw, column_id, identifier_fallback) do
    case column_text(raw, column_id) do
      nil -> identifier_fallback
      "" -> identifier_fallback
      text -> text
    end
  end

  defp labels_value(_raw, nil), do: []

  defp labels_value(raw, column_id) do
    case column_text(raw, column_id) do
      nil ->
        []

      "" ->
        []

      text ->
        text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.downcase/1)
    end
  end

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp profile_value(_raw, nil), do: nil

  defp profile_value(raw, column_id) when is_binary(column_id) do
    case column_text(raw, column_id) do
      nil ->
        nil

      "" ->
        nil

      text ->
        text = String.trim(text)
        if text == "", do: nil, else: text
    end
  end

  defp repo_value(_raw, nil), do: nil

  defp repo_value(raw, column_id) when is_binary(column_id) do
    case column_text(raw, column_id) do
      nil ->
        nil

      "" ->
        nil

      text ->
        text = String.trim(text)
        if text == "", do: nil, else: text
    end
  end

  defp ensure_blank(nil), do: nil

  defp ensure_blank(text) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      _ -> text
    end
  end

  # Linear → Monday mapping: Linear has built-in issue.description; Monday
  # items don't, so the operator-written task body lives in Monday Updates.
  # Concatenate non-Symphony updates oldest-first as the rendered description.
  # Symphony's own writebacks (## Symphony Workpad / ## Symphony Failures /
  # ## Symphony Heartbeat / ## Symphony Completion) are filtered out.
  @symphony_marker_prefixes [
    "## Symphony Workpad",
    "## Symphony Failures",
    "## Symphony Heartbeat",
    "## Symphony Completion",
    "## Symphony PR Refusal"
  ]

  defp description_from_updates(raw) do
    updates = Map.get(raw, "updates", [])

    operator_bodies =
      updates
      |> Enum.sort_by(&Map.get(&1, "created_at", ""))
      |> Enum.map(&Map.get(&1, "body", ""))
      |> Enum.map(&strip_html/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&symphony_marker?/1)
      |> Enum.reject(&(&1 == ""))

    case operator_bodies do
      [] -> nil
      bodies -> Enum.join(bodies, "\n\n---\n\n")
    end
  end

  defp symphony_marker?(text) when is_binary(text) do
    Enum.any?(@symphony_marker_prefixes, &String.starts_with?(text, &1))
  end

  defp symphony_marker?(_), do: false

  # Monday update bodies arrive as HTML; strip tags + decode common entities so
  # the prompt body is plain text that the agent can read cleanly.
  defp strip_html(html) when is_binary(html) do
    html
    |> String.replace(~r/<\/?(p|div|br)[^>]*>/i, "\n")
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace(~r/\n{3,}/, "\n\n")
  end

  defp strip_html(_), do: ""
end
