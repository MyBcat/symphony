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

  defp stamp_line(session) do
    host = Map.get(session, :host, "unknown")
    path = Map.get(session, :workspace_path, "")
    sha = Map.get(session, :short_sha, "no-sha")
    "#{host}:#{path}@#{sha}"
  end

  defp format_started(%{started_at: dt}), do: "at " <> DateTime.to_iso8601(dt)
  defp format_started(_), do: "(time unknown)"
end
