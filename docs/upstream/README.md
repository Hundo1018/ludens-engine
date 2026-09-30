# Upstream candidates (drafts for review; nothing submitted)

Findings from the experiment branch that may be worth taking to
[modular/modular](https://github.com/modular/modular). Each file is a draft
for the repository owner to review. Claude does not submit anything
upstream.

Upstream rules that shape these drafts (`CONTRIBUTING.md`,
`AI_TOOL_POLICY.md` at modular/modular `e700d92`):
- Open an issue before a PR, except for a small obvious fix.
- Keep PRs under ~100 lines.
- Label AI-assisted work (`Assisted-by: AI`), including issues.
- The human author writes the PR description and must be able to answer
  review questions.
- Reports are triaged against nightly, so each draft records a nightly rerun.

| Draft | Kind | Evidence | Status |
|---|---|---|---|
| [wasm32-backend.md](wasm32-backend.md) | feature request | W1/W2 (Mojo → wasm via retargeted IR), `BACKENDS` list, nightly rerun | ready for review; no patch (P0/C1 not done) |
| [o0-build-time.md](o0-build-time.md) | performance report | R2 (n=10 × 2), R2b, R2c (standalone probe, nightly) | weak: the time penalty depends on the code; review whether to file |

Considered and not proposed:
- **Front-end fixed cost** (1.40 s for a one-function module, of which ~0.75 s
  is `Import Mojo` + `VerifyParameters` + `LowerLIT`). This is expected
  behaviour, not a defect. A report would have to propose something, such as
  a resident front end. `tools/compilation-server` exists but serves only the
  LLVM side (`emitArchive`). Not actionable without a design.
- **valgrind cannot see Mojo heap block ends.** Mojo allocates through
  TCMalloc (`Mojo/lib/CompilerRT/Memory.cpp`); ASan builds switch to
  `malloc` (`std/builtin/_startup.mojo`). This is documented in the source;
  at most a docs note. Low value.
- **Guard gaps from R1** (`List` element layout, export signatures). These
  are in this project's hot-reload design, not in Mojo.

Not yet checked: duplicates in the upstream issue tracker. This session's
GitHub access does not cover modular/modular's issues, so the reviewer
should search before filing.
