defmodule SymphonyElixir.Tracker do
  @moduledoc """
  Tracker primitive contract. Symphony owns all Monday writes per Spec 1 DL-005.
  Adapter dispatch resolved at call time from config + optional override.
  """

  alias SymphonyElixir.Config

  @type phi_offender :: %{
          required(:id) => String.t(),
          required(:identifier) => String.t(),
          required(:kinds) => [atom()]
        }

  @type fetch_with_phi_result :: %{
          required(:items) => [term()],
          required(:phi_offenders) => [phi_offender()]
        }

  @callback fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  @callback fetch_candidate_issues_with_phi_findings() ::
              {:ok, fetch_with_phi_result()} | {:error, term()}
  @callback fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  @callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  @callback upsert_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  @callback set_pr_url(String.t(), String.t()) :: :ok | {:error, term()}
  @callback post_failure_update(String.t(), String.t()) :: :ok | {:error, term()}
  @callback post_pr_refusal(String.t(), String.t()) :: :ok | {:error, term()}
  @callback post_phi_refusal(String.t(), String.t()) :: :ok | {:error, term()}
  @callback acquire_heartbeat() :: :ok | {:error, term()}
  @callback release_heartbeat() :: :ok | {:error, term()}
  @callback validate_no_phi(map()) :: :ok | {:error, term()}

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: adapter().fetch_candidate_issues()

  @spec fetch_candidate_issues_with_phi_findings() ::
          {:ok, fetch_with_phi_result()} | {:error, term()}
  def fetch_candidate_issues_with_phi_findings,
    do: adapter().fetch_candidate_issues_with_phi_findings()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: adapter().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: adapter().fetch_issue_states_by_ids(issue_ids)

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name), do: adapter().update_issue_state(issue_id, state_name)

  @spec upsert_workpad(String.t(), String.t()) :: :ok | {:error, term()}
  def upsert_workpad(issue_id, body), do: adapter().upsert_workpad(issue_id, body)

  @spec set_pr_url(String.t(), String.t()) :: :ok | {:error, term()}
  def set_pr_url(issue_id, url), do: adapter().set_pr_url(issue_id, url)

  @spec post_failure_update(String.t(), String.t()) :: :ok | {:error, term()}
  def post_failure_update(issue_id, body), do: adapter().post_failure_update(issue_id, body)

  @spec post_pr_refusal(String.t(), String.t()) :: :ok | {:error, term()}
  def post_pr_refusal(issue_id, body), do: adapter().post_pr_refusal(issue_id, body)

  @spec post_phi_refusal(String.t(), String.t()) :: :ok | {:error, term()}
  def post_phi_refusal(issue_id, body), do: adapter().post_phi_refusal(issue_id, body)

  @spec acquire_heartbeat() :: :ok | {:error, term()}
  def acquire_heartbeat, do: adapter().acquire_heartbeat()

  @spec release_heartbeat() :: :ok | {:error, term()}
  def release_heartbeat, do: adapter().release_heartbeat()

  @spec validate_no_phi(map()) :: :ok | {:error, term()}
  def validate_no_phi(item), do: adapter().validate_no_phi(item)

  @spec adapter() :: module()
  def adapter do
    case Application.get_env(:symphony_elixir, :tracker_adapter_override) do
      nil -> default_adapter_for_kind()
      module -> module
    end
  end

  defp default_adapter_for_kind do
    case Config.settings!().tracker.kind do
      "memory" -> SymphonyElixir.Tracker.MemoryMonday
      _ -> SymphonyElixir.Monday.Adapter
    end
  end
end
