defmodule SymphonyElixir.Monday.PRDetector do
  @moduledoc """
  Scans agent event-stream text for the first GitHub PR URL.
  Pinned regex requires `pull/<digits>` boundary to avoid matching issues, gists,
  or arbitrary github.com URLs.
  """

  @pr_url_regex ~r{https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/\d+(?=\b|/|$)}

  @spec scan(String.t() | nil) :: {:ok, String.t()} | :no_match
  def scan(nil), do: :no_match
  def scan(""), do: :no_match

  def scan(text) when is_binary(text) do
    case Regex.run(@pr_url_regex, text) do
      [url | _] -> {:ok, url}
      nil -> :no_match
    end
  end
end
