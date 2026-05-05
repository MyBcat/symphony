defmodule SymphonyElixir.Secrets.Scrubber do
  @moduledoc """
  Defense-in-depth scrubber that redacts secret-shaped values from log lines
  before they hit Symphony's disk log.

  Per Spec 4 §2.4: "scrubs the agent's stdout/stderr for the resolved secret
  values before they hit Symphony's logs (defense-in-depth match the
  secret_exec.py redaction pattern)." This module does NOT carry resolved
  secret values in process state — that would defeat the purpose. Instead it
  applies regex patterns that match the shape of high-value secret material
  (AWS-prefixed access keys, GitHub-style tokens, generic hex/base64 blobs at
  high entropy length) and replaces matches with `[REDACTED]`.

  The scrubber is intentionally conservative: it errs on the side of leaving
  text in place to avoid breaking debug logs. The stronger contract is the
  existing `secret_exec.py` value-based redaction that already runs inside the
  wrapper.
  """

  @placeholder "[REDACTED]"

  # Match common high-confidence secret shapes. Each pattern is designed to
  # avoid false-positive matches on normal log output (UUIDs, file hashes,
  # short hex IDs) by requiring either a known prefix or a min length that
  # exceeds typical identifiers.
  @patterns [
    # AWS access key ID
    ~r/\bAKIA[0-9A-Z]{16}\b/,
    # AWS secret access key (40 char base64-ish; require leading separator)
    ~r/(?<=[\s:='\"])[A-Za-z0-9\/+=]{40}(?=[\s'\"]|$)/,
    # GitHub fine-grained token
    ~r/\bghp_[A-Za-z0-9]{36,}\b/,
    # GitHub installation token
    ~r/\bghs_[A-Za-z0-9]{36,}\b/,
    # GitHub OAuth user-to-server token
    ~r/\bgho_[A-Za-z0-9]{36,}\b/,
    # Stripe live + test keys
    ~r/\bsk_(live|test)_[A-Za-z0-9]{24,}\b/,
    # Generic Bearer header
    ~r/\bBearer\s+[A-Za-z0-9._\-]{20,}\b/i,
    # ANTHROPIC api keys
    ~r/\bsk-ant-[A-Za-z0-9_\-]{20,}\b/
  ]

  @doc """
  Scrub `line` of any secret-shaped substrings.

  When `additional_values` is provided, those literal values are removed first
  (matches the `secret_exec.py` redaction behavior — the caller must ensure
  these values originate from a trusted source like an env file we just wrote
  ourselves). The list is best-effort and never logged.
  """
  @spec scrub(binary(), [binary()]) :: binary()
  def scrub(line, additional_values \\ [])

  def scrub(line, additional_values) when is_binary(line) and is_list(additional_values) do
    line
    |> redact_literals(additional_values)
    |> redact_patterns()
  end

  def scrub(other, _additional_values), do: other

  @doc """
  Wrap a stream so each binary line is scrubbed before downstream consumers
  see it. Non-binary chunks pass through untouched.
  """
  @spec wrap(Enumerable.t(), [binary()]) :: Enumerable.t()
  def wrap(stream, additional_values \\ []) do
    Stream.map(stream, fn
      line when is_binary(line) -> scrub(line, additional_values)
      other -> other
    end)
  end

  @doc """
  Returns the placeholder string used in place of redacted matches. Public so
  callers can `String.contains?(text, Scrubber.placeholder())` in tests.
  """
  @spec placeholder() :: String.t()
  def placeholder, do: @placeholder

  defp redact_literals(line, []), do: line

  defp redact_literals(line, values) when is_list(values) do
    Enum.reduce(values, line, fn value, acc ->
      cond do
        not is_binary(value) -> acc
        byte_size(value) < 4 -> acc
        true -> String.replace(acc, value, @placeholder)
      end
    end)
  end

  defp redact_patterns(line) do
    Enum.reduce(@patterns, line, fn pattern, acc ->
      Regex.replace(pattern, acc, @placeholder)
    end)
  end
end
