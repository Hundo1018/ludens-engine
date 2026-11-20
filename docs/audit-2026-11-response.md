# Response to the November 2026 ecosystem audit

Two external reports were handed in (an ecosystem analysis and a performance / best-practice report). Their authors had
no Mojo toolchain, so nothing in them was built or run. This page records, claim by claim that was acted on, what the
code said when it was checked here (2026-11-20, Mojo 1.2.0, repositories at their `main`), and what was done.

Standing decisions for this round: **goldens are not regenerated** (so nothing that changes any result bit is done), and
the reports' own "to be verified" items were **not** verified on their behalf.

## Fixed (each with a test that fails before and passes after)

| Finding | What the code said | PR |
|---|---|---|
| engine S-1: an oversized packet blocks `net_poll` for good | confirmed (`shell/web/net_host.mjs`): the packet stayed at the head of the queue and every later call returned -1. **`os_poll` had the identical code**, which the report did not point out | ludens-engine #110 |
| wasm-rt: the C object cache can link a stale object | reproduced: a changed `c_defines` with untouched sources still linked the old object. The name now carries a hash of compiler, flags, defines and source path | ludens-wasm-rt #20 |
| wasm-rt: nothing checks the Mojo release | `pixi.toml` allowed `<2`. Now `<1.3` plus a check of `mojo --version` at build time (`--allow-mojo-version` to override) | ludens-wasm-rt #20 |
| wasm-rt: the signature audit fails open | confirmed: an unparseable `declare` of a library import was skipped. It is now reported | ludens-wasm-rt #20 |
| wasm-rt: `calloc` multiplies unchecked | confirmed, and worse than reported: `calloc(2^62, 8)` returned a small block and `calloc(SIZE_MAX, 2)` never returned (the size-class loop does not end). Now returns NULL | ludens-wasm-rt #20 |
| wasm-rt: no CI | added: a no-Mojo job and the selftest | ludens-wasm-rt #20 |
| core: the timer `canceled` Dict grows without bound | confirmed for cancel of a pending timer (1,500 marks left in a test with 2,000 timers). Cancelling an already-fired handle still leaves one mark per call; documented, not fixed | ludens-core #152 |
| engine imports wgpu-mojo's private `_ffi` / `_backend` at 76 places | confirmed (31 files). 23 of the 28 names were already exported by `wgpu`; the other five are now. The engine imports only from `wgpu`, and a layout rule (R6) keeps it that way | wgpu-mojo #33, ludens-engine #111 |
| engine README: editor "compiled into the same module", `ui/` "empty", dangling "seam below", dependency graph | all four confirmed against the code and corrected. `docs/frontier_plan.md` (a duplicate of the playground's superseded plan) removed | ludens-engine #110 |
| miniaudio-mojo: development Mojo bounded only by `<2` | now `<1.3` (development environment only; the lock already resolved to 1.2.0). No CI in that repository, so nothing ran automatically | miniaudio-mojo #9 (open) |

## Changed, with no measurable effect

| Finding | Result | PR |
|---|---|---|
| core: the contact solver copies a ~0.7 KB struct per call (`var pr = pairs[c]`) | five sites now borrow with `ref`. Gate 458/458, every golden section unchanged. `bench_contact_model` moved by -35 % to +10 % in both directions, which is the machine's run-to-run noise; **no speed-up is claimed** | ludens-core #151 |

## Checked and found not true

| Claim | What was found |
|---|---|
| "Frontier was deleted from the engine and exists nowhere; ludens-playground does not depend on the engine" | the audit read playground's **first commit**: GitHub's default branch of ludens-playground is `docs/bootstrap`, so a plain clone shows 4 files. `main` has 111 commits, `frontier/`, `LICENSE`, CI and pins ludens-engine. The Frontier decision the report asked for does not exist |
| "playground has no licence" | `main` has `LICENSE` |
| "`--fp-mode` of the Mojo build is unknown" | the wasm-rt build prints the count: 1,468 contractible mul+add pairs, 0 `llvm.fmuladd`, 160 explicit `llvm.fma`; the native reference build is `--target-cpu x86-64`, which has no FMA instruction. ludens-core also has `fp-probe`, `fma-parity` and `flag-policy` for exactly this |
| "22,919 vector operations mean wasm SIMD already works" (my own first reading) | they are explicit SIMD types (`Vec3` is a 4-wide float32), not auto-vectorised loops (`llvm.loop.isvectorized` is 0). Whether `opt` without `+simd128` costs real performance is **not measured** |

## Deliberately not done

| Item | Reason |
|---|---|
| anything that changes result bits (P1b tangent basis, P12 gravity / mass division, P9 SIMD accumulators, P6 LBM vectorisation, wasm SIMD) | goldens are not regenerated this round |
| wgpu-mojo `<1.3` bound | its `stable-tracking.yml` moves the lock to the latest stable Mojo every week and files an issue on failure; a bound would stop it from ever testing 1.3 |
| the reports' "待驗證" assumptions (stack-allocated list literals, `Pointer(to=)`, `ref [self]`, `OwnedDLHandle.call`, ...) | not verified on the reports' behalf, by request |
| engine -> core pin (32 commits behind, includes C-ABI 0.9 and a save-format change), unified pin list with a consistency gate, `wasm.toml` schema version | needs its own change with hash and save verification |
| ECS access API, HUD cache, box / sphere draw split, `Runtime._tick` scratch buffers, `GPU.dispatch` borrow, static FFI link, wasm-rt allocator | measure first; none has a benchmark yet |
| a `v0.1.0` tag for ludens-wasm-rt | a release decision; no consumer pins a tag yet |

## Still open, needs the owner

- **ludens-playground default branch** is `docs/bootstrap`. Settings -> General -> Default branch -> `main`. The tools used in this round cannot change repository settings.
- **tests/golden/test_stdout.txt** has no section for `tests/test_timers_cancel.mojo` (the gate reports it as a new section and passes). Recording it is `pixi run gate -- --update-golden`.
- ludens-core #151 and #152, and miniaudio-mojo #9, were open when this page was written.

## Two things about the tools themselves

- The core gate takes about 50 to 60 minutes on four shared cores, and `GATE_TIMEOUT` defaults to 3,600 s. A slower machine will time out.
- A new test file with a tier header that disagrees with its imports makes the whole suite report failure within three minutes (`MISMATCH` in `arch tiers`); the first version of `test_timers_cancel.mojo` hit this.
