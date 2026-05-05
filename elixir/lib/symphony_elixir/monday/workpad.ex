defmodule SymphonyElixir.Monday.Workpad do
  @moduledoc """
  Renders Monday Update body from session state and (at completion) the agent's
  `_symphony_summary.md` workspace file. Symphony writes this; the agent does
  not.
  """

  @marker "## Symphony Workpad"

  @type session :: %{
          required(:identifier) => String.t(),
          required(:profile_name) => String.t(),
          optional(:instance_id) => String.t(),
          optional(:host) => String.t(),
          optional(:workspace_path) => String.t(),
          optional(:short_sha) => String.t(),
          optional(:started_at) => DateTime.t()
        }

  @spec render_session_start(session()) :: String.t()
  def render_session_start(session) do
    stamp = stamp_line(session)
    started = format_started(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Session

    - Started by Symphony #{started}
    - Profile: `#{session.profile_name}`
    - Identifier: `#{session.identifier}`
    """
  end

  @spec render_completion(session(), String.t()) :: String.t()
  def render_completion(session, summary) do
    stamp = stamp_line(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Completion

    Profile: `#{session.profile_name}`

    #{summary}
    """
  end

  @spec render_crash(session(), String.t()) :: String.t()
  def render_crash(session, reason) do
    stamp = stamp_line(session)

    """
    #{@marker}

    ```text
    #{stamp}
    ```

    ### Crashed

    Profile: `#{session.profile_name}`
    Reason: `#{reason}`
    """
  end

  @type failure_input :: %{
          optional(:timestamp) => String.t(),
          optional(:profile_name) => String.t() | nil,
          optional(:repo) => String.t() | nil,
          required(:reason) => atom() | String.t(),
          optional(:message) => String.t() | nil,
          optional(:stderr_tail) => String.t() | nil
        }

  @doc """
  Render the body of a `## Symphony Failures` Monday Update, without the marker
  itself. The marker is prepended by `Monday.Adapter.post_failure_update/2`.

  Format (per Spec 4 §2.4 / SYM-11923123790):

      {ISO8601 UTC timestamp} | profile={profile} | repo={repo} | reason={reason}
      {human-readable error message}
      --- last 20 lines stderr ---
      {stderr tail}

  The `--- last 20 lines stderr ---` section is rendered only when the caller
  supplies a non-empty `:stderr_tail`; many failure paths (profile denial,
  workspace creation, max_turns) have no stderr to attach.
  """
  @spec render_failure(failure_input()) :: String.t()
  def render_failure(input) when is_map(input) do
    timestamp =
      Map.get(input, :timestamp) || DateTime.to_iso8601(DateTime.utc_now())

    profile = stringify_field(Map.get(input, :profile_name))
    repo = stringify_field(Map.get(input, :repo))
    reason = format_reason(Map.fetch!(input, :reason))
    message = Map.get(input, :message) || ""
    stderr_tail = Map.get(input, :stderr_tail) || ""

    header = "#{timestamp} | profile=#{profile} | repo=#{repo} | reason=#{reason}"

    base = [header, message]

    lines =
      if String.trim(to_string(stderr_tail)) == "" do
        base
      else
        base ++ ["--- last 20 lines stderr ---", String.trim_trailing(stderr_tail)]
      end

    Enum.join(lines, "\n")
  end

  @doc """
  Take the last `n` lines of a binary, joined with `\\n`. Returns an empty
  string for nil/empty input. Used to render the stderr/stdout tail in
  `render_failure/1`.
  """
  @spec tail_lines(String.t() | nil, pos_integer()) :: String.t()
  def tail_lines(nil, _n), do: ""
  def tail_lines("", _n), do: ""

  def tail_lines(text, n) when is_binary(text) and is_integer(n) and n > 0 do
    text
    |> String.split("\n")
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  defp stamp_line(session) do
    host = Map.get(session, :host, "unknown")
    path = Map.get(session, :workspace_path, "")
    sha = Map.get(session, :short_sha, "no-sha")
    "#{host}:#{path}@#{sha}"
  end

  defp format_started(%{started_at: dt}), do: "at " <> DateTime.to_iso8601(dt)
  defp format_started(_), do: "(time unknown)"

  defp stringify_field(nil), do: "unknown"
  defp stringify_field(""), do: "unknown"
  defp stringify_field(value) when is_binary(value), do: value
  defp stringify_field(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_field(value), do: inspect(value)

  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
