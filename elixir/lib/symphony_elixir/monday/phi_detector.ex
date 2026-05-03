defmodule SymphonyElixir.Monday.PHIDetector do
  @moduledoc """
  Pattern-based PHI detection for Monday item content. Tech Board is a no-PHI
  surface per Spec 1 DL-011. This detector refuses items whose title or
  description matches PHI patterns at ingestion.

  Patterns are intentionally conservative: false positives are preferred over
  false negatives because false positives surface as "fix the item text," while
  false negatives risk HIPAA exposure.
  """

  @ssn ~r/\b\d{3}-\d{2}-\d{4}\b/
  @dob ~r/\b(0?[1-9]|1[0-2])[\/\-](0?[1-9]|[12]\d|3[01])[\/\-](19|20)\d{2}\b/
  @patient_name_context ~r/\b(?:patient|pt\.?|insured|enrollee|member)\s+([A-Z][a-z]{2,}\s+[A-Z][a-z]{2,})\b/i

  @type finding :: {:ssn | :dob | :patient_name, String.t()}

  @spec scan(String.t() | nil) :: :clean | {:phi, [finding()]}
  def scan(nil), do: :clean
  def scan(""), do: :clean

  def scan(text) when is_binary(text) do
    findings =
      []
      |> append_findings(:ssn, Regex.scan(@ssn, text))
      |> append_findings(:dob, Regex.scan(@dob, text))
      |> append_findings(:patient_name, Regex.scan(@patient_name_context, text, capture: :all_but_first))

    case findings do
      [] -> :clean
      list -> {:phi, list}
    end
  end

  defp append_findings(acc, _kind, []), do: acc

  defp append_findings(acc, kind, matches) do
    Enum.reduce(matches, acc, fn match, inner_acc ->
      case match do
        [_full | rest] when rest != [] -> [{kind, hd(rest)} | inner_acc]
        [text] -> [{kind, text} | inner_acc]
        text when is_binary(text) -> [{kind, text} | inner_acc]
      end
    end)
  end
end
