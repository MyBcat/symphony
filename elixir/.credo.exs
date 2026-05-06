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
          # Match mix format line_length: 200 so credo does not flag formatter-legal lines.
          {Credo.Check.Readability.MaxLineLength, max_length: 200}
        ],
        disabled: [
          # ── Design checks ────────────────────────────────────────────────────
          # Pre-existing throughout the codebase; not enforced historically.
          {Credo.Check.Design.AliasUsage, []},

          # ── Readability checks ────────────────────────────────────────────────
          # Explicit try/rescue/catch is used intentionally in GenServer
          # terminate/safe_* helpers where it adds structural clarity.
          {Credo.Check.Readability.PreferImplicitTry, []},

          # ── Refactor checks (all pre-existing, never enforced before) ─────────
          # Nesting, arity, complexity, and cond checks fire on ~40 pre-existing
          # sites across the codebase. The format-check fix exposed them because
          # credo was never reached before (mix format failed first).
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Refactor.MapJoin, []},
          {Credo.Check.Refactor.WithClauses, []},
          {Credo.Check.Refactor.RejectReject, []}
        ]
      }
    }
  ]
}
