defmodule SymphonyElixir.AutoMerge.State do
  @moduledoc """
  Persists `{item_id, pr_url}` -> reviewed-at timestamp across Symphony
  restarts so a freshly opened PR isn't re-reviewed every time the
  agent_runner observes a stream replay.

  The state file defaults to `state/auto_merge_state.json` (resolved from
  the current working directory when Symphony runs from `elixir/`). Tests
  override the path via the `:auto_merge_state_path` application env.

  Storage shape (Spec 4 §2.8a M-6 fix — list-of-URLs per item to cover
  multi-attempt items where each attempt opens a distinct PR):

      {
        "<item_id>": {
          "reviews": [
            {"url": "...", "reviewed_at": "<iso8601>"},
            {"url": "...", "reviewed_at": "<iso8601>"}
          ]
        }
      }

  The legacy single-record shape (`{"url": ..., "reviewed_at": ...}` with
  no `reviews` key) is read transparently for backward compatibility with
  state files written by earlier builds — the legacy entry is treated as
  a one-element review list and left in place until the next write
  upgrades the on-disk shape.

  Records are not deleted by Symphony — operators prune by hand.
  """

  @default_state_path "state/auto_merge_state.json"
  @lock_retry_ms 25
  @lock_timeout_ms 5_000

  @typedoc """
  Per-(item_id, pr_url) review record: the URL the agent opened the PR
  at and the timestamp Symphony auto-reviewed it.
  """
  @type record :: %{url: String.t(), reviewed_at: String.t()}

  @doc "Resolve the configured state file path."
  @spec path() :: String.t()
  def path do
    Application.get_env(:symphony_elixir, :auto_merge_state_path, @default_state_path)
  end

  @doc """
  Returns `true` when `(item_id, url)` has already been auto-reviewed.

  Treats unreadable / corrupted state as "not reviewed" — fail-open is
  acceptable here because the only consequence is one extra Codex review
  run on the same PR (mildly wasteful, never destructive).
  """
  @spec reviewed?(String.t(), String.t()) :: boolean()
  def reviewed?(item_id, url) when is_binary(item_id) and is_binary(url) do
    case lookup_all(item_id) do
      {:ok, records} ->
        Enum.any?(records, fn %{url: stored_url} -> stored_url == url end)

      _ ->
        false
    end
  end

  def reviewed?(_item_id, _url), do: false

  @doc """
  Look up the most recent review record for `item_id`. Returns
  `:not_found` when the item has never been reviewed.

  Kept primarily as a backward-compatible inspection API; the
  `reviewed?/2` predicate is what the AutoMerge gates actually use.
  """
  @spec lookup(String.t()) :: {:ok, record()} | :not_found | {:error, term()}
  def lookup(item_id) when is_binary(item_id) and item_id != "" do
    case lookup_all(item_id) do
      {:ok, []} -> :not_found
      {:ok, [latest | _]} -> {:ok, latest}
      :not_found -> :not_found
      {:error, _} = err -> err
    end
  end

  def lookup(_item_id), do: :not_found

  @doc """
  Look up every recorded review for `item_id`, newest-first. Returns
  `:not_found` for items with no records.
  """
  @spec lookup_all(String.t()) :: {:ok, [record()]} | :not_found | {:error, term()}
  def lookup_all(item_id) when is_binary(item_id) and item_id != "" do
    case load_all() do
      {:ok, map} ->
        case Map.get(map, item_id) do
          nil -> :not_found
          entry -> {:ok, normalize_entry_records(entry)}
        end

      {:error, _} = err ->
        err
    end
  end

  def lookup_all(_item_id), do: :not_found

  @doc """
  Mark `(item_id, url)` as reviewed at the current UTC timestamp. If a
  prior record for the same `(item_id, url)` exists, its timestamp is
  refreshed; if a prior record for the same `item_id` but a *different*
  url exists, the new record is appended.
  """
  @spec mark_reviewed(String.t(), String.t()) :: :ok | {:error, term()}
  def mark_reviewed(item_id, url)
      when is_binary(item_id) and item_id != "" and is_binary(url) and url != "" do
    new_record = %{
      "url" => url,
      "reviewed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with_lock(fn ->
      case load_all() do
        {:ok, map} ->
          existing_records = entry_records(Map.get(map, item_id))

          merged =
            existing_records
            |> Enum.reject(fn %{"url" => stored_url} -> stored_url == url end)
            |> List.insert_at(0, new_record)

          new_map = Map.put(map, item_id, %{"reviews" => merged})
          write_all(new_map)

        {:error, _} = err ->
          err
      end
    end)
  end

  def mark_reviewed(_item_id, _url), do: {:error, :invalid_arguments}

  @doc false
  @spec record(String.t(), record()) :: :ok | {:error, term()}
  def record(item_id, %{url: url, reviewed_at: reviewed_at})
      when is_binary(item_id) and item_id != "" and is_binary(url) and url != "" and
             is_binary(reviewed_at) do
    new_record = %{"url" => url, "reviewed_at" => reviewed_at}

    with_lock(fn ->
      case load_all() do
        {:ok, map} ->
          existing_records = entry_records(Map.get(map, item_id))

          merged =
            existing_records
            |> Enum.reject(fn %{"url" => stored_url} -> stored_url == url end)
            |> List.insert_at(0, new_record)

          new_map = Map.put(map, item_id, %{"reviews" => merged})
          write_all(new_map)

        {:error, _} = err ->
          err
      end
    end)
  end

  def record(_item_id, _record), do: {:error, :invalid_record}

  @doc false
  @spec reset!() :: :ok
  def reset! do
    _ = File.rm(path() <> ".lock")

    case File.rm(path()) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  defp load_all do
    state_path = path()

    case File.read(state_path) do
      {:ok, ""} ->
        {:ok, %{}}

      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> {:ok, map}
          {:ok, _other} -> {:error, :invalid_state_file}
          {:error, reason} -> {:error, {:state_decode_failed, reason}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_all(map) do
    state_path = path()
    dir = Path.dirname(state_path)
    tmp_path = state_path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         {:ok, body} <- Jason.encode(map, pretty: true),
         :ok <- File.write(tmp_path, body),
         :ok <- File.rename(tmp_path, state_path) do
      :ok
    else
      {:error, _} = err ->
        _ = File.rm(tmp_path)
        err
    end
  end

  defp with_lock(fun) when is_function(fun, 0) do
    lock_path = path() <> ".lock"
    deadline = System.monotonic_time(:millisecond) + @lock_timeout_ms

    acquire_lock(lock_path, deadline, fun)
  end

  defp acquire_lock(lock_path, deadline, fun) do
    _ = File.mkdir_p(Path.dirname(lock_path))

    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          IO.write(io, "#{inspect(self())}\n")
          fun.()
        after
          File.close(io)
          File.rm(lock_path)
        end

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :state_lock_timeout}
        else
          Process.sleep(@lock_retry_ms)
          acquire_lock(lock_path, deadline, fun)
        end

      {:error, reason} ->
        {:error, {:state_lock_failed, reason}}
    end
  end

  # Returns the raw on-disk record list for an item entry. Handles three
  # shapes: nil (no entry), legacy single-record, and current
  # `{"reviews": [...]}` shape.
  defp entry_records(nil), do: []
  defp entry_records(%{"reviews" => list}) when is_list(list), do: list

  defp entry_records(%{"url" => _url, "reviewed_at" => _reviewed_at} = legacy_record),
    do: [legacy_record]

  defp entry_records(_other), do: []

  # Normalize the on-disk records into the typed `record()` shape (atom
  # keys), newest-first. Used by `lookup/1` and `lookup_all/1`.
  defp normalize_entry_records(entry) do
    entry
    |> entry_records()
    |> Enum.map(&normalize_record/1)
  end

  defp normalize_record(%{"url" => url, "reviewed_at" => reviewed_at})
       when is_binary(url) and is_binary(reviewed_at) do
    %{url: url, reviewed_at: reviewed_at}
  end

  defp normalize_record(%{url: url, reviewed_at: reviewed_at})
       when is_binary(url) and is_binary(reviewed_at) do
    %{url: url, reviewed_at: reviewed_at}
  end

  defp normalize_record(other) when is_map(other) do
    %{
      url: stringify(Map.get(other, "url") || Map.get(other, :url)),
      reviewed_at: stringify(Map.get(other, "reviewed_at") || Map.get(other, :reviewed_at))
    }
  end

  defp normalize_record(_other), do: %{url: "", reviewed_at: ""}

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
