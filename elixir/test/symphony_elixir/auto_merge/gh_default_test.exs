defmodule SymphonyElixir.AutoMerge.GH.DefaultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.AutoMerge.GH.Default

  describe "input validation" do
    test "pr_diff_line_count rejects invalid url types" do
      assert {:error, :invalid_pr_url} = Default.pr_diff_line_count(nil)
      assert {:error, :invalid_pr_url} = Default.pr_diff_line_count("")
      assert {:error, :invalid_pr_url} = Default.pr_diff_line_count(:not_a_string)
    end

    test "pr_view_base rejects invalid url types" do
      assert {:error, :invalid_pr_url} = Default.pr_view_base(nil)
      assert {:error, :invalid_pr_url} = Default.pr_view_base("")
      assert {:error, :invalid_pr_url} = Default.pr_view_base(:not_a_string)
    end

    test "pr_merge rejects invalid url types" do
      assert {:error, :invalid_pr_url} = Default.pr_merge(nil)
      assert {:error, :invalid_pr_url} = Default.pr_merge("")
      assert {:error, :invalid_pr_url} = Default.pr_merge(:not_a_string)
    end
  end
end
