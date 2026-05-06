%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      checks: %{
        disabled: [
          # Pre-existing throughout the codebase; not enforced historically.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
