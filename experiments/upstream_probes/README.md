# Upstream probes

These are the measurements behind [docs/upstream/PRIORITY.md](../../docs/upstream/PRIORITY.md).

```sh
python3 experiments/upstream_probes/run.py <path to mojo>        # 12 rows, exit 1 on any mismatch
python3 experiments/upstream_probes/pass_cost.py <mojo> experiments/upstream_probes/probe_empty.mojo 5
```

Each row compares a predicted outcome with the observed one. A new Mojo
release that changes an outcome shows up as `MISMATCH`.

The predictions for the unload rows were written in `host_rand.mojo` and
`host_swap_global.mojo` before the first run. The other rows record outcomes
first seen while researching PRIORITY.md; they are regression checks, not
pre-registered predictions.

| File | What it checks |
|---|---|
| `probe_global_var.mojo` | a module-level `var` is rejected |
| `probe_wasm_target.mojo` | `--target-triple wasm32-unknown-unknown` is rejected |
| `probe_extcall_two_sigs.mojo` | one C symbol with two `external_call` signatures is rejected (intended upstream) |
| `probe_thin_field.mojo` | a `def(Int) thin -> Int` struct field works |
| `probe_type_eq.mojo` | compile-time type identity through `reflect[T].name` |
| `probe_stdlib_global.mojo` | `std.ffi._Global` as a process-wide counter |
| `plugin_rand.mojo`, `host_rand.mojo` | exit-time SIGSEGV after unloading a plugin that used `std.random` |
| `lib_global_v1.mojo`, `lib_global_v100.mojo`, `host_swap_global.mojo` | `_Global` survives a module swap; the same exit-time SIGSEGV |
| `probe_empty.mojo`, `pass_cost.py` | fixed build cost and its split by MLIR pass |

## Results, 2026-09-30

- Mojo 1.1.0 (8189361e): 12/12 rows match.
- Nightly 1.2.0.dev2026093005 (b3556108): 12/12 rows match.

Linux x86-64, 4 vCPU. Five runs per unload row.

The first control for `host_swap_global` was wrong and is recorded here. It
kept the `OwnedDLHandle` until the end of `main`, but that handle is still
destroyed before `DestroyGlobals` runs. A second attempt used a raw
`external_call["dlopen"]`, which did not compile: it conflicts with the
stdlib's own `dlopen` declaration. The working control pins the library with
`_DLHandle`, which never closes it.
