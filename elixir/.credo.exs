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
        extra: [
          {Credo.Check.Readability.MaxLineLength, max_length: 200}
        ],
        disabled: [
          # Pre-existing throughout the codebase; not enforced historically.
          {Credo.Check.Design.AliasUsage, []},
          # Explicit try/rescue/catch blocks are used in many GenServer terminate
          # and safe_* helpers; converting to implicit try would lose clarity.
          {Credo.Check.Readability.PreferImplicitTry, []}
        ]
      }
    }
  ]
}
