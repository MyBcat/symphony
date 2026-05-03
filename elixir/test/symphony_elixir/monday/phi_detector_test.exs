defmodule SymphonyElixir.Monday.PHIDetectorTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Monday.PHIDetector

  describe "scan/1" do
    test "returns :clean on safe engineering text" do
      text = "Fix Bland AI bot for client ABC-001 — supervisor reports timing issue."
      assert PHIDetector.scan(text) == :clean
    end

    test "flags SSN pattern" do
      text = "Patient context: 123-45-6789 reported issue."
      assert {:phi, [{:ssn, _}]} = PHIDetector.scan(text)
    end

    test "flags DOB pattern (MM/DD/YYYY)" do
      text = "DOB: 03/14/1985 confirmed."
      assert {:phi, [{:dob, _}]} = PHIDetector.scan(text)
    end

    test "flags plausible full-name pattern in patient context" do
      text = "Patient John Smith requested follow-up."
      assert {:phi, [{:patient_name, _}]} = PHIDetector.scan(text)
    end

    test "does not flag titles like 'fix Symphony Codex tool' as patient names" do
      text = "Fix Symphony Codex tool injection."
      assert PHIDetector.scan(text) == :clean
    end

    test "returns multiple findings when multiple patterns match" do
      text = "Patient Jane Doe DOB 01/02/1990 SSN 555-44-3333"
      assert {:phi, findings} = PHIDetector.scan(text)
      kinds = Enum.map(findings, &elem(&1, 0))
      assert :ssn in kinds
      assert :dob in kinds
      assert :patient_name in kinds
    end
  end
end
