defmodule SymphonyElixir.PRSafety.BranchPolicyTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.PRSafety.BranchPolicy

  describe "expected_pattern/1" do
    test "returns the canonical pattern with the item id substituted" do
      assert BranchPolicy.expected_pattern("11923258050") ==
               "symphony/SYM-11923258050/attempt-N"
    end

    test "falls back to placeholder when the item id is empty" do
      assert BranchPolicy.expected_pattern("") =~ "symphony/SYM-<id>/attempt-N"
    end
  end

  describe "validate/2" do
    test "accepts canonical attempt-1 branch" do
      assert :ok =
               BranchPolicy.validate("symphony/SYM-11923258050/attempt-1", "11923258050")
    end

    test "accepts attempt-N for any positive integer N" do
      assert :ok =
               BranchPolicy.validate("symphony/SYM-11923258050/attempt-7", "11923258050")

      assert :ok =
               BranchPolicy.validate("symphony/SYM-11923258050/attempt-42", "11923258050")
    end

    test "rejects non-numeric item ids even when the branch text matches them" do
      assert {:error, {:branch_convention_violation, "symphony/SYM-foo/attempt-1", expected}} =
               BranchPolicy.validate("symphony/SYM-foo/attempt-1", "foo")

      assert expected == "symphony/SYM-foo/attempt-N"
    end

    test "rejects branches that target a different SYM id" do
      assert {:error, {:branch_convention_violation, "symphony/SYM-9999/attempt-1", expected}} =
               BranchPolicy.validate("symphony/SYM-9999/attempt-1", "11923258050")

      assert expected =~ "symphony/SYM-11923258050/attempt-N"
    end

    test "rejects branches that lack the attempt-N suffix" do
      assert {:error, {:branch_convention_violation, "symphony/SYM-11923258050", _}} =
               BranchPolicy.validate("symphony/SYM-11923258050", "11923258050")

      assert {:error, {:branch_convention_violation, "symphony/SYM-11923258050/", _}} =
               BranchPolicy.validate("symphony/SYM-11923258050/", "11923258050")
    end

    test "rejects branches with non-numeric attempt suffix" do
      assert {:error, {:branch_convention_violation, _, _}} =
               BranchPolicy.validate("symphony/SYM-11923258050/attempt-x", "11923258050")
    end

    test "rejects attempt zero and leading-zero attempt suffixes" do
      assert {:error, {:branch_convention_violation, _, _}} =
               BranchPolicy.validate("symphony/SYM-11923258050/attempt-0", "11923258050")

      assert {:error, {:branch_convention_violation, _, _}} =
               BranchPolicy.validate("symphony/SYM-11923258050/attempt-01", "11923258050")
    end

    test "rejects trailing branch suffixes after the attempt number" do
      assert {:error, {:branch_convention_violation, _, _}} =
               BranchPolicy.validate(
                 "symphony/SYM-11923258050/attempt-99/extra-suffix",
                 "11923258050"
               )
    end

    test "rejects branches outside the symphony/ prefix" do
      assert {:error, {:branch_convention_violation, "main", _}} =
               BranchPolicy.validate("main", "11923258050")

      assert {:error, {:branch_convention_violation, "feature/whatever", _}} =
               BranchPolicy.validate("feature/whatever", "11923258050")
    end

    test "rejects non-binary head" do
      assert {:error, {:branch_convention_violation, "", _}} =
               BranchPolicy.validate(nil, "11923258050")
    end
  end
end
