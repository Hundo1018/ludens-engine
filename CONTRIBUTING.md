# Contributing

## Before you open a PR

```sh
pixi run gate            # build, arch-check, unit..system tiers, golden compare
pixi run gate -- --selftest
```

CI runs the same two commands on every PR (`.github/workflows/ci.yml`). A
behaviour-preserving change must leave every golden section identical; a new
test file adds a section — record it with `pixi run gate -- --update-golden`
after checking the diff.

## Rules that the gate does not catch

- Layering: a package imports only strictly lower layers
  (`scripts/arch_layers.toml`, `docs/ARCHITECTURE.md` §1). `arch-check` enforces it;
  update both files in the same commit when adding a package.
- Every `tests/test_*.mojo` starts with `# tier: <unit|component|integration|system|stress>`.
- Replaceable subsystems sit behind a trait, chosen at compile time, with a
  parity test and a `BENCHMARK_REPORT.md` row. Performance claims come with numbers.
- Engine packages do not `print`; inner loops do not `raise`.
- Error classes and where they are handled: `docs/ARCHITECTURE.md` §2.

## Commits

Conventional Commits, scope = package, ROADMAP number in parentheses:

```
feat(physics): ropes and cables (17.41)
fix(collision): ...
docs: progress notes for 17.42
```

`pixi run changelog` builds `CHANGELOG.md` from these subjects (needs a full,
non-shallow clone).

## Licensing of contributions

The project is dual licensed MIT OR Apache-2.0. Unless you state otherwise,
any contribution you submit for inclusion is dual licensed the same way,
without additional terms or conditions.
