# Hot reload, phase 1: pure Mojo, native target

A Mojo host process swaps in a rebuilt Mojo engine `.so` while the simulation
keeps running. There is no C, no wasm and no JS in this phase.

```bash
python3 -m venv .venv && .venv/bin/pip install mojo==1.1.0   # or the pixi env
python3 experiments/hot_reload/native/run_native.py           # build + matrix + bench
make hot-native                                               # same

# hot compile: edit engine.mojo while this runs
python3 experiments/hot_reload/native/dev_native.py --run-host
make hot-native-dev                                           # same
python3 experiments/hot_reload/native/e2e_native.py --rounds 6  # automated check
```

Toolchain: Mojo **1.1.0** (the version `pixi.toml` pins), installed from PyPI.
The engine imports dev's `ecs.SparseSet`, so `run_native.py` precompiles `diag`,
`geometry` and `ecs` into `build/` first. `max` is not needed.

## 0. Problem

The engine code lives in a shared library, and its state holds pointers: heap
`List`s inside `ecs.SparseSet`, and a `StaticString` into the library's own
read-only data. When the library is replaced (`dlopen` of the new build,
`dlclose` of the old one):

- which state survives, and which pointers are left dangling?
- which swap methods stay correct for which edits?
- how long does a swap take, and how long does the rebuild take?

## 1. Setup

`engine.mojo` exports C-ABI functions (`@export` … `abi("C")`), built with
`mojo build --emit shared-lib`. `host.mojo` loads it with
`OwnedDLHandle(path, RTLD.NOW | RTLD.LOCAL)`. The `EngineState` lives in a block
the **host** allocates (`engine_state_size()` bytes) and passes by address:

| Field | Type | Points at |
|---|---|---|
| `capacity`, `frame` | `Int` | – |
| `box_x` | `Float32` | – |
| `label` | `StaticString` | literal in the `.so` that ran `engine_init` / `engine_rebind` (phase 1; H2 replaced it with `label_id: Int`) |
| `entities` | `ecs.SparseSet[Float32]` | heap `List`s allocated by the `.so` that created them |

Strategies (`host.mojo`):

| Strategy | Swap |
|---|---|
| `restart` | destroy state, unload old, `engine_init` in new (control) |
| `keep` | leave the state block as is; old `.so` stays loaded |
| `close` | leave the state block as is; unload old |
| `rebind` | `close` + new `engine_rebind` re-points `label` at its own literal |
| `snapshot` | old `engine_save` → destroy → unload → new `engine_load` into a fresh block |
| `auto` | `rebind` if `engine_state_size` and `engine_layout_id` match, else `snapshot` |
| `samepath` | rename the new `.so` onto the old file's path, then `dlopen` that path |

`engine_layout_id` hashes the state size and the byte offset of each field,
measured on a live instance.

## 2–3. Edits and predictions

`run_native.py` builds each variant by a text edit of `engine.mojo`:

| Variant | Edit |
|---|---|
| v2_code | `SPEED` 60→120, `COLOR` red→green |
| v3_label | label literal `…v1` → `…v3` |
| v4_layout | `var speed_scale: Float32` inserted as the first field |
| v5_swap | `capacity` and `frame` declarations swapped |
| v6_append | `var extra: Int` appended, incremented every frame |

`PREDICTED` in `run_native.py` was written before the first matrix run.

## 4–5. Measurement

Each cell runs in its own host process on private copies of both `.so` files,
so a crash is recorded as `trap` instead of ending the run. Protocol, same as
the wasm phase: `init(8)`, 30 frames, despawn 2 and 5, 10 frames, swap, 30 frames.

- **state** is compared exactly with a Python float32 oracle: count, frame,
  color, dense keys, and the bit pattern of every draw x.
  - `ok`: equals the oracle for the new code **and** the new module's code ran
  - `stale-code`: equals the oracle for the old code **and** the old module's code ran
  - `lost`: count 8, frame 30 (the restart signature)
  - `corrupt`: anything else; `trap`: the process died first
- **label** is where the state's `label` pointer points, looked up in
  `/proc/self/maps`: `old` / `new` / `none` (unmapped). It is `trap` when
  reading through it killed the process.
- **code** is which module's code ran, found the same way from the address
  of the module's own literal (`engine_module_addr`). A file renamed over while
  mapped shows up as `(deleted)`, which identifies the old inode under `samepath`.

## 6–9. Results (35 cells, all match the predictions)

This is the phase 1 record (label as a `StaticString`). The H2 section below
has the current engine's matrix.

| Strategy | v2_code | v3_label | v4_layout | v5_swap | v6_append |
|---|---|---|---|---|---|
| restart | lost/new | lost/new | lost/new | lost/new | lost/new |
| keep | ok/old | ok/old | trap | corrupt/old | ok/old ⚠ |
| close | ok/**trap** | ok/**trap** | trap | corrupt/trap | ok/trap |
| rebind | ok/new | ok/new | trap | corrupt/new | ok/new ⚠ |
| snapshot | ok/new | ok/new | ok/new | ok/new | ok/new |
| auto | ok/new (rebind) | ok/new (rebind) | ok/new (snapshot) | ok/new (snapshot) | ok/new (snapshot) |
| samepath | stale-code/old | stale-code/old | stale-code/old | stale-code/old | stale-code/old |

What the matrix shows:

1. **Unloading really unmaps the old `.so`.** `/proc/self/maps` holds 5
   mappings before `dlclose` and 0 after, so Mojo libraries are not pinned
   (no `NODELETE`).
2. **Heap state survives unloading. Pointers into the old library's static
   data do not.** Under `close`, the `SparseSet` lists (allocated by the old
   `.so`) still read correctly. The `label` pointer points into no mapping
   (`none`), and reading it is a SIGSEGV in `engine_label_byte`. This is the
   native form of the wasm phase's stale `.rodata`: there the old text
   survived silently, here the pointer is dangling.
3. **One allocator for all modules.** Under `rebind`, the new `.so` frees lists
   allocated by the unloaded one (`teardown=ok`). `readelf -d` shows why: the
   engine `.so` has `NEEDED libKGENCompilerRTShared.so`, so every engine
   module shares the host's runtime. (`ldd` printed "statically linked" for
   it, which is wrong.) The `.so` exports only `engine_*` symbols, so the
   runtime cannot be interposed between modules.
4. **Layout edits corrupt in-place swaps.**
   - v4: the new code reads the old `box_x` bits as `frame` (`1109393438` =
     `0x42200000` = 40.0f), then crashes on the misread `SparseSet`.
   - v5: `frame` ends at 38 (the old capacity 8, plus 30 updates).
   - The size + offset guard in `auto` rejects both and falls back to `snapshot`.
5. **`dlopen` by path returns the already-loaded library.** With the new
   build renamed onto the old path while the old one is loaded, the host keeps
   running the old code (`stale-code`, code owner = the `(deleted)` inode). A
   hot reloader has to load every build from a new path.
6. ⚠ **v6_append under `keep`/`rebind`** matches the oracle, but the new code
   writes `extra` past the end of the host's block, which was sized for the
   old struct. That is an out-of-bounds heap write this matrix cannot see. It
   was not checked with a sanitizer (valgrind is not installed here). The size
   guard rejects it, so `auto` never takes that path.

### Latency (`run_native.py bench`, Xeon 2.8 GHz × 4)

| | median | p95 | max |
|---|---|---|---|
| swap `restart` | 108 µs | 165 µs | 419 µs |
| swap `rebind` | 98 µs | 169 µs | 354 µs |
| swap `snapshot` (6 entities) | 105 µs | 134 µs | 191 µs |
| rebuild engine `.so` (`mojo build --emit shared-lib`) | 1.11 s | – | 3.26 s |

Swap time includes `dlopen`, which dominates it. The first build of each
variant took 2.9–3.5 s. The dev loop is bounded by the compiler, not by the swap.

## Hot compile (`dev_native.py` + `live_host.mojo`)

`dev_native.py` polls `engine.mojo` every 100 ms (since H5, also the packages
it imports; see below). On each change it runs
`mojo build --emit shared-lib` into `build/hot_native/dev/<n>/libengine.so`
(a new path each time, because of finding 5). After a successful build it
atomically replaces `dev/latest` with `"<n> <path>"`; a failed build leaves
`latest` alone.

`live_host.mojo` runs the engine at about 60 Hz and reads `latest` every
frame. On a new version it loads the candidate first; only when that works
does it hand the state over (phase 1: `rebind` if the layout matched, else
`snapshot`; since H1 with a guarded probation, see below). A candidate that
fails to load is reported, and the old module keeps running.

`e2e_native.py` edits a copy of `engine.mojo` while both run:

| Edit | Result (1 run, 6 code-edit rounds) |
|---|---|
| SPEED/COLOR, 6 times | 6/6 swapped via `rebind`, `frame_before == frame_after`, 6 entities, color turns green |
| syntax error | build fails in 0.43 s; host frame keeps advancing (690 → 720) on the old module |
| fix + insert a field | swapped via `snapshot`, frame continues, 6 entities |

Latency from writing the file to the host's swap line (n = 7): **median
1.08 s, max 3.29 s** (the first build). `mojo build` alone: median 0.98 s. The
swap itself: 25–37 µs. Almost all of the latency is the compiler.

**Correction (2026-09-30): the 1.08 s median was mostly compile-cache hits.**
The e2e alternated `SPEED` between two values, and `mojo build` caches builds.
`build_time.py --probe-cache` (3 reps each, same machine):

| Condition | `mojo build` median |
|---|---|
| same path, same content | 0.93 s |
| same path, only a trailing comment changed | 0.93 s |
| same path, mtime bumped | 1.00 s |
| same path, `SPEED` set to a value never built | **3.11 s** |
| same content at a path never built | 2.74 s (0.90 s once that path was built) |

The cache (`~/.cache/modular/.mojo_cache/`) is keyed on the path and the code
with comments dropped. `e2e_native.py` now uses a `SPEED` value never built
before in every round. Re-measured (n = 5): **edit → swap median 3.03 s, max
3.09 s; `mojo build` median 2.94 s.**

## H2: no pointers into a `.so` in the state

Phase 1 kept `label: StaticString` in `EngineState` and needed `engine_rebind`
to re-point it after each swap; nothing checked that rebind covered every such
field. H2 replaces it with `label_id: Int`. The text comes from
`label_text(id)` in the code, so it always comes from the running module.
`engine_rebind` is gone, and the `rebind` strategy with it (without a rebind
step it is `close`). `auto` now keeps the block in place (`inplace`) when the
layout matches.

Predictions, written before the run (`PREDICTED` in `run_native.py`; the phase 1
table is kept as `PREDICTED_PHASE1`): `keep` and `close` × v2/v3/v6 go from
`ok/old` and `ok/trap` to `ok/new`; the other cells do not change. A `new` label
now also requires the new variant's text (`ludens: engine v3` for v3).

| Strategy | v2_code | v3_label | v4_layout | v5_swap | v6_append |
|---|---|---|---|---|---|
| restart | lost/new | lost/new | lost/new | lost/new | lost/new |
| keep | ok/new | ok/new | trap | corrupt/new | ok/new ⚠ |
| close | ok/new | ok/new | trap | corrupt/new | ok/new ⚠ |
| snapshot | ok/new | ok/new | ok/new | ok/new | ok/new |
| auto | ok/new (inplace) | ok/new (inplace) | ok/new (snapshot) | ok/new (snapshot) | ok/new (snapshot) |
| samepath | stale-code/old | stale-code/old | stale-code/old | stale-code/old | stale-code/old |

30/30 match. e2e: 4 code edits swapped `inplace`, the syntax error kept the old
module, the layout edit went through `snapshot`.

**Compile-time rule** (`nostatic.mojo`). `assert_no_static_refs[EngineState]()`
runs inside `engine_state_size`. It rejects a direct field whose type's
`reflect[].base_name()` is `StringSpan` (what `StaticString` reports),
`StringSlice`, `Span`, `Pointer`, `UnsafePointer` or `OpaquePointer`.

- `run_native.py test` builds `x_static_field` (adds `var note: StaticString`)
  and requires the build to fail with
  `constraint failed: state field holds a pointer or string view: note`. It does.
- Gap, shown in `probes/probe_nostatic.mojo`: type parameters of containers are
  not inspected. `SparseSet[StaticString]` passes the check.

## H1: roll back a build that crashes

Without a guard, a new build whose `engine_update` faults kills `live_host`
and the state with it. H1 follows cr.h: guard the first frames after a swap
with `sigsetjmp` / `siglongjmp` and return to the previous module on a fault.

**Probe first** (`probes/probe_sigjmp.mojo`):
- `__sigsetjmp` / `siglongjmp` through `external_call` recover from a SIGSEGV
  three times in a row.
- Mojo 1.1 has no global variables ("global variables are not supported"), so
  the handler cannot find the jmp_buf through one. The jmp_buf lives on a page
  mapped at a fixed address (`mmap` with `MAP_FIXED_NOREPLACE`); the handler
  knows it as a compile-time constant.
- A local incremented between `sigsetjmp` and the fault read 0 afterwards.
  Locals are indeterminate after the jump, as in C, so the guarded functions
  keep nothing live across the call; the state is in the heap block.
- One symbol cannot be declared with two signatures: `signal(sig, handler)`
  and `signal(sig, SIG_DFL)` in one module fail to lower. The reset uses
  `bsd_signal`.

**Design** (`guard.mojo`, `live_host.mojo`):
1. Before a swap, the old module saves a snapshot of the state (the
   rollback copy), and the old module stays loaded.
2. For the next 60 frames every `engine_update` of the new module runs under
   the guard (`guarded_update`); on the snapshot path `engine_load` does as
   well (`guarded_load`).
3. On a fault the old module rebuilds the state from the snapshot and keeps
   running (`rollback`). The block the new code ran on is leaked, because
   destroying it could fault again.
4. After 60 clean frames the old module is unloaded and the snapshot freed
   (`commit`).
5. A fault while no guarded call runs restores the default action, so the
   process dies as before: `probes/probe_guard_unarmed.mojo` exits with 139.

**Predictions** (written in `e2e_native.py` before implementing) and results:

| Edit | Predicted | Observed |
|---|---|---|
| 4a null write in `engine_update`, same layout | host lives, `rollback`, frame = swap's frame_before, 6 entities, old colour ticks on | `rollback at=update signal=11 frame=880` (frame_before 880), 6 entities, green ticks 900, 930 |
| 4b same + appended field (snapshot path) | same | `rollback … frame=1102` (frame_before 1102), 6 entities, ticks 1110, 1140 |
| 4c crash removed | in-place swap, `commit` | `swap used=inplace`, `commit frames=60` |

Cost with 6 entities: rollback copy 144 bytes, saved in 1.3–2.2 µs;
rollback 6–7 µs. How the copy scales with the entity count is measured in H3.
The `swap_us` column now excludes the copy and the unload of the old module
(which moves to `commit`), so it reads 2–9 µs instead of 25–37 µs.

Limits:
- Only faults in the first 60 frames are caught.
- A fault while the engine holds a lock (for example inside `malloc`) leaves the
  lock held. Not tested.
- The fixed guard address can be taken in another process layout; then
  `guard_install` raises at start-up.

## H3: snapshots from reflection schemas, migration by field name

The phase 1 snapshot was a hand-written word array: every added, removed or
renamed field meant editing `engine_save` / `engine_load`. H3 serialises with
dev's `ecs/schema.mojo` (built for save games), which generates the field
table from `reflect[T]` at compile time.

**Engine layout.** `EngineState { entities: SparseSet[Float32]; core: Core }`:
- `Core` holds only plain data (`capacity`, `frame`, `box_x`, `label_id`).
  It is written as one self-describing record (`write_value`).
- Entities are written as a batch of `Entity { key, x }` records (`write_values`).
- `core` is the last field, so a field appended to `Core` is appended to the
  whole state, as before (v6, the H4 target).
- `engine_layout_id` is now an FNV-1a hash over `schema_of[EngineState]`
  (every dotted field name, type name, offset and size), so there is no
  hand-kept list of fields left.

**ABI.** `engine_save(state) -> buffer` returns `[u64 length][bytes]`, which
the host frees; this works because all modules share one allocator.
`engine_load(state, buffer)` returns 1 (ok), 0 (corrupt), 2 (unresolved
rename) or 3 (a field changed type).

**Migration rule.** `read_value` matches stored fields to current ones by name:
- an added field keeps the value `Core(0)` gives it;
- a deleted field is skipped.

A load that both drops a stored field and defaults a current one looks like a
rename. It is retried with the aliases in `migrate()`
(`alias_field(sch, "offset_x", "box_x")` reads stored `box_x` into `offset_x`).
If it still looks like one, the load is refused (code 2); the field is not
silently zeroed. The aliases are only applied to such loads, so a stale alias
does not break the next swap.

**New variants.**
- `v7_delete` removes `capacity`, the first `Core` field.
- `v8_rename` renames `box_x` to `offset_x` everywhere.
- `v8_rule` is v8 plus the one-line alias.

**Predictions** (`PREDICTED_H3`, written before the run):
- the phase 1 and H2 columns do not change;
- `keep`/`close` × v7: `corrupt|trap` (the new code reads `frame` from `capacity`'s slot);
- `keep`/`close` × v8: `ok/new` (same offsets);
- `snapshot`/`auto` × v7: `ok/new`;
- `snapshot`/`auto` × v8_rename: `rejected`. The layout id hashes field names,
  so `auto` takes the snapshot path;
- `snapshot`/`auto` × v8_rule: `ok/new`.

| Strategy | v2 | v3 | v4 | v5 | v6 | v7_delete | v8_rename | v8_rule |
|---|---|---|---|---|---|---|---|---|
| restart | lost/new | lost/new | lost/new | lost/new | lost/new | lost/new | lost/new | lost/new |
| keep | ok/new | ok/new | corrupt | corrupt/new | ok/new ⚠ | corrupt (label `?`) | ok/new | ok/new |
| close | ok/new | ok/new | corrupt | corrupt/new | ok/new ⚠ | corrupt (label `?`) | ok/new | ok/new |
| snapshot | ok/new | ok/new | ok/new | ok/new | ok/new | ok/new | **rejected** (code 2) | ok/new |
| auto | ok/new (inplace) | ok/new (inplace) | ok/new (snapshot) | ok/new (snapshot) | ok/new (snapshot) | ok/new (snapshot) | **rejected** (code 2) | ok/new (snapshot) |
| samepath | stale-code/old | … | … | … | … | … | … | stale-code/old |

48/48 match.
- The first run had 47/48: `auto` × v8_rename was `rejected` as predicted, but
  the host returned before printing `used=`, so the `used` check failed. The
  host now prints `used=` before the rejection. This was a harness bug, not a
  wrong prediction.
- `keep`/`close` × v4 changed from `trap` (H2) to `corrupt`, which is still
  inside the predicted set. With the entities first, the inserted field no
  longer shifts the `SparseSet`, so the new code misreads numbers instead of
  a heap pointer.

**Snapshot cost** (`bench_snapshot.py`, median of 7; save + load, and every
load compared field by field with the original):

| Entities | hand-written bytes | hand ms | schema bytes | schema ms |
|---|---|---|---|---|
| 9 | 192 | 0.001 | 516 | 0.004 |
| 999 | 16 032 | 0.009 | 12 396 | 0.079 |
| 99 999 | 1 600 032 | 1.57 | 1 200 396 | **9.30** |

Gate (< 16.7 ms at 100k): passed. The schema format is 25% smaller (12 bytes per
entity against 16) and 5.9× slower at 100k; `write_values` appends one byte
at a time (the 17.11 to-do in ROADMAP.md). The H1 rollback copy uses the same
format, so with 100k entities each swap spends about 4 ms saving it.

In the live loop (e2e), the 6-entity snapshot is 480–541 bytes and takes
6–29 µs to save; the H2 hand format took 144 bytes and 1.3–2.2 µs.

**Build cost.** `build_time.py --unique` (4 reps, interleaved, code never
built before): H2 engine 2.74 s, H3 engine 3.04 s. Importing `ecs.schema` adds
about 0.3 s to every engine build. The first attempt at this comparison
appended a unique *comment* per build, which the cache ignores; `--unique` now
appends an unused `comptime` constant.

## H5: hot compile follows the packages the engine imports

`dev_native.py` now also polls every `.mojo` file of `diag/`, `geometry/`
and `ecs/` (under `--packages-root`). For a changed package it:
1. re-precompiles that package into `--include`;
2. re-precompiles every package that imports it, directly or not, in
   `PACKAGES` order (found by scanning the `from X` / `import X` lines);
3. rebuilds the engine.

A failed precompile keeps the previous `.mojoc` and is retried on the next
change. The e2e runs on copies of the packages and its own include directory,
so the repository tree is not touched.

Prediction (written in `e2e_native.py` first): make `SparseSet.__len__` in
the copy of `ecs/` return `len + 100`; then the build line says `pkgs=ecs`,
`build_s = pkg_s + engine_s`, the swap is in place, and ticks report
`count=106`. Result: `pkgs=ecs pkg_s=2.48 engine_s=3.97`, in-place swap,
`count=106`; edit → swap 6.56 s. The engine rebuild saw the new `ecs.mojoc`:
the compile cache does not hand back a stale engine when only an imported
package changed.

On the first run the build line and the host's swap line were printed at the
same moment by two threads and merged into one line, so the check timed
out. `dev_native.py` now prints under a lock, and prints the build line
before publishing, so it always comes before the swap.

## 10. Updated model

- `snapshot` is correct for every edit here, and `auto` (layout guard →
  in place, else `snapshot`) is correct as well.
- An in-place swap needs three things:
  1. the same layout (size and offsets),
  2. no pointer into the old module's static data in the state: since H2
     there is none, and `nostatic.mojo` rejects direct fields of pointer or
     string-view type at compile time,
  3. heap memory from a shared allocator, which holds here.
- Each build must be loaded from a unique path.
- A real code edit costs about 3 s of `mojo build` on this machine; about
  0.9 s only when the (path, code) pair was built before.

## 11. Limits and next steps

- The state is small: 6 entities, one `SparseSet`. Snapshot cost against state
  size was not measured natively; the wasm phase has that scaling.
- Only one kind of static pointer (a string literal) was tested. Function
  pointers or trait objects stored in the state would dangle the same way;
  not tested. Mojo 1.1 rejects a `def(Int) -> Int` field type ("struct
  fields do not support trait types"), so a function-pointer field needs
  another form to test.
- Snapshot cost against state size: measured in H3 (9.3 ms for 100k entities).
- The migration rule cannot tell a rename from a delete plus an unrelated
  add in the same edit; that edit needs an alias or is refused.
- A field whose type changes is refused (code 3); no variant tests it.

## Files

| File | Role |
|---|---|
| `engine.mojo` | engine as a reloadable `.so`; `@@…@@` markers are where the edits go |
| `hotswap.mojo` | shared: `Engine` wrapper over the C ABI, state blocks, maps lookup |
| `bench_snapshot.mojo`, `bench_snapshot.py` | H3: snapshot size and time, hand-written vs schema, 10 / 1k / 100k entities |
| `host.mojo` | runs one (old, new, strategy) cell and prints observations |
| `live_host.mojo` | runs the engine continuously and swaps in each published build |
| `dev_native.py` | hot compile: watch → `mojo build` → publish `latest` (optionally starts the host) |
| `e2e_native.py` | edits the source three ways while the host runs; measures edit → swap latency |
| `run_native.py` | builds the variants and host, runs the matrix vs. the oracle, benchmarks |
| `guard.mojo` | fault guard for H1: fixed-address jmp_buf page, handler, `guarded_update` / `guarded_load` |
| `nostatic.mojo` | compile-time rule: no pointer / string-view fields in the state (H2) |
| `build_time.py` | times `mojo build`, interleaved; `--unique`, `--probe-cache` |
| `probes/` | small programs that each answer one question about the toolchain |
