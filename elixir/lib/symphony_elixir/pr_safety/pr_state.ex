defmodule SymphonyElixir.PRSafety.PRState do
  @moduledoc """
  Persists per-item PR head SHA + URL across Symphony agent runs so the
  force-push detector in `SymphonyElixir.PRSafety` has the previous head SHA
  to compare against.

  The state file defaults to `state/pr_state.json` resolved from the current
  working directory (i.e. `elixir/state/pr_state.json` when Symphony runs
  from `elixir/`). Tests override the path via the
  `:pr_safety_state_path` application env so they don't trample real state.

  Storage shape:

      {
        "<item_id>": {"url": "...", "sha": "..."}
      }

  The file is rewritten atomically (write to `<path>.tmp`, then rename) on
  every `record/2` call. Records are not deleted by Symphony — operators
  prune by hand if needed.
  """

  @default_state_path "state/pr_state.json"

  @typedoc """
  Per-item PR record: the URL the agent opened the PR at and the head SHA
  that was current the first time Symphony saw the PR.
  """
  @type record :: %{url: String.t(), sha: String.t()}

  @doc """
  Resolve the configured state file path. Defaults to `state/pr_state.json`
  relative to the current working directory.
  """
  @spec path() :: String.t()
  def path do
    Application.get_env(:symphony_elixir, :pr_safety_state_path, @default_state_path)
  end

  @doc """
  Load the per-item record for `item_id`. Returns `:not_found` when the file
  is absent or the item has not been recorded yet.
  """
  @spec lookup(String.t()) ::
          {:ok, record()} | :not_found | {:error, term()}
  def lookup(item_id) when is_binary(item_id) and item_id != "" do
    case load_all() do
      {:ok, map} ->
        case Map.get(map, item_id) do
          nil -> :not_found
          record -> {:ok, normalize_record(record)}
        end

      {:error, _} = err ->
        err
    end
  end

  def lookup(_item_id), do: :not_found

  @doc """
  Record (or overwrite) the PR record for `item_id`. The on-disk JSON file
  is rewritten atomically. Failures bubble up so the caller can decide
  whether to refuse or continue best-effort.
  """
  @spec record(String.t(), record()) :: :ok | {:error, term()}
  def record(item_id, %{url: url, sha: sha} = _record)
      when is_binary(item_id) and item_id != "" and is_binary(url) and is_binary(sha) do
    case load_all() do
      {:ok, map} ->
        new_map = Map.put(map, item_id, %{"url" => url, "sha" => sha})
        write_all(new_map)

      {:error, _} = err ->
        err
    end
  end

  def record(_item_id, _record), do: {:error, :invalid_record}

  @doc false
  @spec reset!() :: :ok
  def reset! do
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
      {:error, _} = err -> err
    end
  end

  defp normalize_record(%{"url" => url, "sha" => sha}) when is_binary(url) and is_binary(sha) do
    %{url: url, sha: sha}
  end

  defp normalize_record(%{url: url, sha: sha}) when is_binary(url) and is_binary(sha) do
    %{url: url, sha: sha}
  end

  defp normalize_record(other) do
    %{url: stringify(Map.get(other, "url") || Map.get(other, :url)),
      sha: stringify(Map.get(other, "sha") || Map.get(other, :sha))}
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
