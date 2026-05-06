defmodule SymphonyElixir.Tracker.MemoryMonday do
  @moduledoc """
  In-memory Monday-shaped Tracker backend used in tests. Backed by an Agent
  process keyed by the calling test pid for isolation.
  """

  @behaviour SymphonyElixir.Tracker

  use Agent

  @impl true
  def fetch_candidate_issues, do: {:ok, get_state(:items_active, [])}

  @impl true
  def fetch_candidate_issues_with_phi_findings do
    case get_state(:phi_findings_result, nil) do
      nil ->
        {:ok, %{items: get_state(:items_active, []), phi_offenders: []}}

      result ->
        result
    end
  end

  @impl true
  def fetch_issues_by_states(states), do: {:ok, get_state({:items_in_states, states}, [])}

  @impl true
  def fetch_issue_states_by_ids(_ids) do
    case get_state(:item_states_result, nil) do
      nil -> {:ok, get_state(:item_states, [])}
      result -> result
    end
  end

  @impl true
  def update_issue_state(item_id, state) do
    push_event({:status_write, item_id, state})
    :ok
  end

  @impl true
  def upsert_workpad(item_id, body) do
    push_event({:workpad_write, item_id, body})
    :ok
  end

  @impl true
  def set_pr_url(item_id, url) do
    push_event({:pr_write, item_id, url})
    :ok
  end

  @impl true
  def post_failure_update(item_id, body) do
    push_event({:failure_write, item_id, body})
    :ok
  end

  @impl true
  def post_pr_refusal(item_id, body) do
    push_event({:pr_refusal_write, item_id, body})
    :ok
  end

  @impl true
  def post_phi_refusal(item_id, body) do
    push_event({:phi_refusal_write, item_id, body})
    :ok
  end

  @impl true
  def post_codex_review(item_id, body) do
    push_event({:codex_review_write, item_id, body})
    :ok
  end

  @impl true
  def post_auto_merge_failure(item_id, body) do
    push_event({:auto_merge_failure_write, item_id, body})
    :ok
  end

  @impl true
  def acquire_heartbeat do
    case get_state(:heartbeat, :unlocked) do
      :unlocked -> put_state(:heartbeat, :locked)
      :locked -> {:error, :lock_held_by_other}
    end
  end

  @impl true
  def release_heartbeat do
    put_state(:heartbeat, :unlocked)
    :ok
  end

  @impl true
  def validate_no_phi(_item), do: :ok

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.merge([name: __MODULE__], opts))
  end

  @spec set(atom() | tuple(), term()) :: :ok
  def set(key, value), do: put_state(key, value)

  @spec events() :: [tuple()]
  def events, do: get_state(:events, [])

  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)

  defp get_state(key, default) do
    ensure_started()
    Agent.get(__MODULE__, fn s -> Map.get(s, key, default) end)
  end

  defp put_state(key, value) do
    ensure_started()
    Agent.update(__MODULE__, fn s -> Map.put(s, key, value) end)
    :ok
  end

  defp push_event(event) do
    ensure_started()

    Agent.update(__MODULE__, fn s ->
      Map.update(s, :events, [event], &[event | &1])
    end)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, _} = start_link([])
      _pid -> :ok
    end
  end
end
