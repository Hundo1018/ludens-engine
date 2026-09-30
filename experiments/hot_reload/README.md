# Experiment: hot reload of the wasm engine core

Replace the running engine module with a rebuilt one, in the browser, without
restarting the simulation.

```bash
python3 experiments/hot_reload/run.py          # build + matrix + bench + browser e2e
python3 experiments/hot_reload/run.py test     # only the variant x strategy matrix
python3 experiments/hot_reload/dev_server.py   # interactive: open
#   http://127.0.0.1:8080/experiments/hot_reload/ and edit engine_hot.c
```

## 0. Problem

All engine state (the `EngineState` statics, the SparseSet on the bump heap)
lives in wasm linear memory. A rebuilt module starts with fresh memory. How can
that state move into the new instance, for which kinds of source edits is each
method correct, and how long does a swap take?

## 1. Candidate methods

| Strategy | Mechanism | Needs from the module |
|---|---|---|
| `restart` | new instance + `engine_init` (control: state is discarded) | nothing |
| `memcopy` | copy the old linear memory byte-for-byte into the new instance | identical data layout |
| `memcopy-rw` | `memcopy`, but keep the new module's `.rodata` segment (range parsed from the binary's data + name sections) | identical writable layout |
| `snapshot` | `engine_save()` writes a schema-1 record (`capacity, frame, box_x, dense keys`); `engine_load()` rebuilds from it | save/load exports |
| `auto` | `memcopy-rw` only if every layout guard passes, else `snapshot` | guards below |

Layout guards compared (v1 = old module, vN = new):

- **addresses**: `__data_end` and `__heap_base` globals equal
- **layoutId**: `engine_layout_id()`, an FNV hash of `sizeof`/`offsetof` of `EngineState`, compiled into the module
- **map**: hash of `(section, symbol, address, size)` for every `.data`/`.bss` symbol in the wasm-ld link map (`--Map`, parsed by `layout_map.py`)

## 2–3. Variants (the "edits") and predictions

`engine_hot.c` is built once per variant with `-D` knobs, all through the
normal `scripts/emit-and-link.sh` back-half.

| Variant | Edit |
|---|---|
| v2_code | `SPEED` 60→120, `COLOR` red→green (code-only) |
| v3_rodata | log text `…v1` → `…v3`, same length |
| v4_layout | new field inserted at the front of `EngineState` |
| v5_swap | two same-size fields of `EngineState` swapped |
| v6_static | new unrelated `static` declared before `g`; `EngineState` unchanged |

Predictions were written into `hot_reload.test.mjs` before each run. v2–v5
came first; v6 and the map guard were added after round 1's refutation.

## 4–5. Measurement

Per (strategy, variant) cell in `hot_reload.test.mjs`: v1 runs `init(8)`, 30
frames, despawns 2 and 5, 10 more frames; swap; `engine_log_msg()`; 30 frames.
Classification against a float32 JS oracle (`Math.fround`, reusing the
SparseSet oracle from `tests/differential`):

- `ok`: entity count, frame counter **and** every last-frame draw command equal the oracle exactly
- `lost`: count = 8 and frame = 30 (restart signature)
- `corrupt`: otherwise; `trap`: exception
- msg `new`/`old`: which log text the new code printed

## 6–9. Results

### Guards (v1 → variant)

| Variant | addresses | layoutId | map | memcopy actually correct? |
|---|---|---|---|---|
| v2_code | match | match | match | yes |
| v3_rodata | match | match | match | state yes, rodata stale |
| v4_layout | **match** | differ | differ | no |
| v5_swap | match | differ | **match** | no |
| v6_static | match | **match** | differ | yes |

### Strategy × variant (state/msg)

| Strategy | v2_code | v3_rodata | v4_layout | v5_swap | v6_static |
|---|---|---|---|---|---|
| restart | lost/new | lost/new | lost/new | lost/new | lost/new |
| memcopy | ok/new | ok/**old** | corrupt/new | corrupt/new | ok/new |
| memcopy-rw | ok/new | ok/new | corrupt/new | corrupt/new | ok/new |
| snapshot | ok/new | ok/new | ok/new | ok/new | ok/new |
| auto | ok/new (memcopy-rw) | ok/new (memcopy-rw) | ok/new (snapshot) | ok/new (snapshot) | ok/new (snapshot) |

### Refuted predictions

1. **v4 addresses would differ. Observed: equal.** At `-O2`, LLVM GlobalOpt
   splits `static EngineState g` into scalar globals `g.0`…`g.3` (see
   `build/hot/v1/engine_hot.ll` and the link map). The added 4 bytes land in
   the alignment padding before the 16-aligned `g_snap`, so `__data_end` does
   not move. Consequence: the address guard cannot detect struct edits, and
   `engine_layout_id` describes the source struct, not the memory layout that
   ships.
2. **v6 memcopy would be corrupt (new static placed before `g`). Observed: ok.**
   wasm-ld placed `g_updates` at `0x434`, after `g.3`, in padding. No existing
   address moved. The map guard still reports a difference, so it rejects a
   swap that would have been safe. That error is on the safe side: `auto`
   falls back to `snapshot`.

### Latency (`run.py bench`, 200 reps, Node 22.22, Xeon 2.8 GHz × 4, 2315-byte module, 1000 entities)

Every rep swaps in distinct bytes (a unique custom section), so a compiled-module
cache cannot hide compile time.

| Strategy | compile median / p95 | total median / p95 (ms) |
|---|---|---|
| restart | 0.30 / 0.61 | 0.48 / 0.84 |
| memcopy-rw | 0.30 / 0.50 | 0.51 / 0.83 |
| snapshot | 0.29 / 0.42 | 0.48 / 0.69 |
| auto | 0.29 / 0.95 | 0.54 / 1.46 |

Transfer cost vs. the old instance's memory size (median ms, 40 reps):

| Memory | memcopy | memcopy-rw | snapshot |
|---|---|---|---|
| 1 MiB | 0.73 | 0.80 | 0.028 |
| 4 MiB | 2.87 | 2.71 | 0.027 |
| 16 MiB | 11.25 | 11.74 | 0.030 |
| 64 MiB | 64.88 | 62.42 | 0.032 |

`memcopy` scales at roughly 1 ms/MiB. Past about 16 MiB it no longer fits a
16.7 ms frame. `snapshot` scales with the size of the state (here ~670
entities), not with the memory size.

### Browser loop (`e2e.py`, headless Chromium)

`dev_server.py` polls the source every 200 ms, rebuilds into
`build/hot/dev/<n>/`, and pushes each build over SSE. `web_hot.mjs` swaps with
`auto` between two frames. The e2e test edits a copy of `engine_hot.c` three
times:

| Edit | Expected | Observed (6/6 runs pass) |
|---|---|---|
| SPEED/COLOR | `memcopy-rw`, frame counter continues, 10 entities, green | yes; build ≈ 220–340 ms, swap ≈ 1–3 ms |
| syntax error | build error shown, old module keeps running | yes |
| fix + `LAYOUT_V2` | `snapshot`, frame counter continues, 10 entities | yes; swap ≈ 0.6–1.2 ms |

The first run failed the frame-continuity check on edit 3 (108 → 109). The
cause was a bug in the page's measurement, not lost state: `frameBefore` was
read before `await compile`, and one animation frame ran on the old module
during compilation. It is now read after instantiation, where only microtasks
run before the transfer.

## 10. Updated model

- **`snapshot` is the default that stays correct.** It is layout-independent
  and cheaper than copying memory. Its cost is a save/load pair per piece of
  state, versioned by schema. For the Mojo core this means `engine_save` and
  `engine_load` belong in the engine ABI (and in `wit/ludens.wit` once the
  component path is real).
- **Whether a memory transplant is safe is a property of the linked binary,
  not of the source.** The optimizer (GlobalOpt SRA) and the linker (padding
  placement) decide the layout. No single guard is complete: layoutId misses
  v6-style placement changes, and the map fingerprint misses v5 because
  SRA-split fields are named by position (`g.0`, `g.1`). Only the combination
  covered all five edits here, and it is still conservative (v6 rejected).
  `memcopy-rw` is an optimisation for code-only edits, not the primary path.
- **Copying the whole memory resurrects stale `.rodata`** (v3). Any memory
  transplant must at least skip the new module's read-only segments.

## 11–12. Limits and next steps

- The engine is the C stand-in, not Mojo. Mojo lowers through the same LLVM
  passes, so GlobalOpt SRA is expected to apply as well. Re-run this matrix
  once `mojo` can emit IR (STATUS.md).
- The module is 2.3 KB. Compile time for a realistic Mojo core (hundreds of KB)
  has not been measured. Streaming compile (`compileStreaming`) and a worker
  are the obvious next steps if it exceeds a frame.
- Snapshot schema migration is shown for one added field (v4 defaults
  `speed_scale`). Removed or retyped fields need an explicit per-version
  migrator.
- Only scalar statics and one SparseSet are covered. Function-pointer tables
  (`__indirect_function_table`) and host-held handles into memory are not
  handled by either strategy.

## Files

| File | Role |
|---|---|
| `engine_hot.c` | engine core with edit knobs, `engine_layout_id`, `engine_save`/`engine_load` |
| `hot_reload.mjs` | strategies, guards, wasm data-segment/name reader, `hotSwap()` |
| `hot_reload.test.mjs` | variant × strategy matrix vs float32 oracle, with pre-registered predictions |
| `bench.mjs` | raw latency samples (swap phases, memory-size scaling) |
| `layout_map.py` | link-map → writable-symbol fingerprint |
| `run.py` | builds variants, runs test/bench/e2e, summarises the bench |
| `dev_server.py` | watch → rebuild → SSE dev server |
| `index.html`, `web_hot.mjs` | browser page that hot-swaps on each build |
| `e2e.py`, `e2e_browser.mjs` | headless-Chromium end-to-end check of the dev loop |
