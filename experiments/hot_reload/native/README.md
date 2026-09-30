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
| `label` | `StaticString` | literal in the `.so` that ran `engine_init` / `engine_rebind` |
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

`dev_native.py` polls `engine.mojo` every 100 ms. On each change it runs
`mojo build --emit shared-lib` into `build/hot_native/dev/<n>/libengine.so`
(a new path each time, because of finding 5). After a successful build it
atomically replaces `dev/latest` with `"<n> <path>"`; a failed build leaves
`latest` alone.

`live_host.mojo` runs the engine at about 60 Hz and reads `latest` every
frame. On a new version it loads the candidate first; only when that works
does it hand the state over with `swap_auto` (shared with the matrix host in
`hotswap.mojo`). A candidate that fails to load is reported, and the old
module keeps running.

`e2e_native.py` edits a copy of `engine.mojo` while both run:

| Edit | Result (1 run, 6 code-edit rounds) |
|---|---|
| SPEED/COLOR, 6 times | 6/6 swapped via `rebind`, `frame_before == frame_after`, 6 entities, color turns green |
| syntax error | build fails in 0.43 s; host frame keeps advancing (690 → 720) on the old module |
| fix + insert a field | swapped via `snapshot`, frame continues, 6 entities |

Latency from writing the file to the host's swap line (n = 7): **median
1.08 s, max 3.29 s** (the first build). `mojo build` alone: median 0.98 s. The
swap itself: 25–37 µs. Almost all of the latency is the compiler.

## 10. Updated model

- `snapshot` is correct for every edit here, and `auto` (layout guard →
  `rebind`, else `snapshot`) is correct as well.
- An in-place swap needs three things:
  1. the same layout (size and offsets),
  2. every pointer into the old module's static data re-pointed (`engine_rebind`),
  3. heap memory from a shared allocator, which holds here.

  Item 2 has no automatic check. A new `StaticString` field that
  `engine_rebind` forgets would reproduce the `close` crash.
- Each build must be loaded from a unique path.

## 11. Limits and next steps

- The state is small: 6 entities, one `SparseSet`. Snapshot cost against state
  size was not measured natively; the wasm phase has that scaling.
- Only one kind of static pointer (a string literal) was tested. Function
  pointers or trait objects stored in the state would dangle the same way;
  not tested.
- The snapshot format is hand-written. dev's `ecs/schema.mojo` (reflection
  schemas, used for save games) could produce it instead; not tried.
- The watcher polls one file. Edits to packages the engine imports (`ecs`,
  `geometry`) need `run_native.py build` to re-precompile them first.

## Files

| File | Role |
|---|---|
| `engine.mojo` | engine as a reloadable `.so`; `@@…@@` markers are where the edits go |
| `hotswap.mojo` | shared: `Engine` wrapper over the C ABI, state blocks, maps lookup, `swap_auto` |
| `host.mojo` | runs one (old, new, strategy) cell and prints observations |
| `live_host.mojo` | runs the engine continuously and swaps in each published build |
| `dev_native.py` | hot compile: watch → `mojo build` → publish `latest` (optionally starts the host) |
| `e2e_native.py` | edits the source three ways while the host runs; measures edit → swap latency |
| `run_native.py` | builds the variants and host, runs the matrix vs. the oracle, benchmarks |
