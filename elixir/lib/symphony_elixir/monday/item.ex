defmodule SymphonyElixir.Monday.Item do
  @moduledoc """
  Normalize Monday item payloads into Symphony's issue model.

  Identifier scheme: `<config.identifier_prefix>-<item.id>` (per Spec 1 DL-004).

  PHI rejection: item title and description column are scanned via
  `SymphonyElixir.Monday.PHIDetector`; on hit, returns `{:error, {:phi_detected, findings}}`.
  Tech Board is a no-PHI surface per Spec 1 DL-011.
  """

  alias SymphonyElixir.Monday.PHIDetector

  @type config :: %{
          identifier_prefix: String.t(),
          symphony_status_column_id: String.t(),
          priority_column_id: String.t() | nil,
          description_column_id: String.t() | nil,
          branch_column_id: String.t() | nil,
          labels_column_id: String.t() | nil
        }

  @type t :: %{
          id: String.t(),
          identifier: String.t(),
          title: String.t(),
          description: String.t() | nil,
          priority: integer() | nil,
          state: String.t(),
          branch_name: String.t(),
          url: String.t() | nil,
          labels: [String.t()],
          blocked_by: [map()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil
        }

  @spec from_monday(map(), config()) ::
          {:ok, t()} | {:error, {:missing_column, String.t()} | {:phi_detected, [PHIDetector.finding()]}}
  def from_monday(raw, config) when is_map(raw) and is_map(config) do
    title = Map.get(raw, "name", "")
    description = column_text(raw, config[:description_column_id])

    with :clean <- PHIDetector.scan(title),
         :clean <- PHIDetector.scan(description),
         {:ok, state} <- require_column_text(raw, config.symphony_status_column_id) do
      identifier = "#{config.identifier_prefix}-#{raw["id"]}"

      item = %{
        id: raw["id"],
        identifier: identifier,
        title: title,
        description: description,
        priority: priority_value(raw, config[:priority_column_id]),
        state: state,
        branch_name: branch_value(raw, config[:branch_column_id], identifier),
        url: Map.get(raw, "url"),
        labels: labels_value(raw, config[:labels_column_id]),
        blocked_by: [],
        created_at: Map.get(raw, "created_at"),
        updated_at: Map.get(raw, "updated_at")
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
      nil -> []
      "" -> []
      text -> text |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.downcase/1)
    end
  end
end
