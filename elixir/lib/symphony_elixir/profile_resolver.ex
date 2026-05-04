defmodule SymphonyElixir.ProfileResolver do
  @moduledoc """
  Resolves which agent Profile handles a Tracker.Issue.

  Precedence (Spec 2 DL-008):
  1. Per-issue Monday Symphony Profile column value (re-resolved at every retry)
  2. agent.default_profile
  3. Error :no_default

  Sandbox safety floor (DL-006) is enforced before returning a profile.
  """

  alias SymphonyElixir.Tracker

  @adapter_for_kind %{
    codex: SymphonyElixir.Codex.Adapter,
    claude: SymphonyElixir.Claude.Adapter,
    gemini: SymphonyElixir.Gemini.Adapter
  }

  @type resolve_error ::
          :no_default
          | {:unknown_profile, String.t()}
          | {:unknown_kind, atom()}
          | {:safety_floor_violation, String.t(), atom(), :config, map()}

  @spec resolve(Tracker.Issue.t(), map(), String.t() | nil, map()) ::
          {:ok, SymphonyElixir.Profile.t()} | {:error, resolve_error()}
  def resolve(%Tracker.Issue{profile: profile_name}, profiles, default, floor)
      when is_map(profiles) do
    name = first_non_blank([profile_name, default])

    cond do
      is_nil(name) ->
        {:error, :no_default}

      not Map.has_key?(profiles, name) ->
        {:error, {:unknown_profile, name}}

      true ->
        check_safety_floor(profiles[name], floor)
    end
  end

  defp first_non_blank(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _ ->
        nil
    end)
  end

  defp check_safety_floor(
         %SymphonyElixir.Profile{kind: kind, config: cfg, name: name} = profile,
         floor
       ) do
    case Map.fetch(@adapter_for_kind, kind) do
      {:ok, adapter} ->
        kind_floor = Map.get(floor, Atom.to_string(kind), %{})

        if adapter.passes_safety_floor?(cfg, kind_floor) do
          {:ok, profile}
        else
          {:error, {:safety_floor_violation, name, kind, :config, cfg}}
        end

      :error ->
        {:error, {:unknown_kind, kind}}
    end
  end

  @spec validate_drift(map(), [String.t()]) ::
          {:ok, %{missing_in_dropdown: [String.t()], orphan_dropdown_labels: [String.t()]}}
  def validate_drift(profiles, dropdown_labels)
      when is_map(profiles) and is_list(dropdown_labels) do
    profile_names = Map.keys(profiles)
    label_set = MapSet.new(dropdown_labels)
    profile_set = MapSet.new(profile_names)

    {:ok,
     %{
       missing_in_dropdown: profile_set |> MapSet.difference(label_set) |> Enum.sort(),
       orphan_dropdown_labels: label_set |> MapSet.difference(profile_set) |> Enum.sort()
     }}
  end
end
