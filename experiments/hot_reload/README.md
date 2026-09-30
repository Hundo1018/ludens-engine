# Experiment: hot reload

Replace the running engine code with a rebuilt version without restarting the
simulation. The experiment runs in two phases, in this order:

| Phase | Target | Engine / host | Run | Write-up |
|---|---|---|---|---|
| 1 | native `.so` | pure Mojo (engine uses dev's `ecs.SparseSet`) | `make hot-native`, `make hot-native-dev` (hot compile) | [native/README.md](native/README.md) |
| 2 | wasm | C stand-in core → wasm, JS host, browser dev loop | `make hot-reload`, `make hot-dev` | [wasm/README.md](wasm/README.md) |

How other languages implement hot reload (Handmade Hero, cr.h, Live++,
Unreal, .NET, JVM, Dart, Rust Subsecond, Erlang, Vite, React, Python, Unity,
Common Lisp, Go, Zig) and how they compare with these results:
[PRIOR_ART.md](PRIOR_ART.md).

Both phases use the same protocol: init 8 entities, 30 frames, despawn two,
10 frames, swap, 30 frames. Both use the same kinds of edits and the same
strategy families, and predictions are recorded before each run.

## Results across both targets

| Finding | Native (Mojo `.so`) | wasm |
|---|---|---|
| Keep the state where it is, swap the code | works for code-only edits | works for code-only edits (`memcopy`) |
| Pointers into the old module's static data | **dangling**: SIGSEGV once the old `.so` is unloaded | **stale**: old `.rodata` copied along; old text printed |
| Fix for those pointers | `engine_rebind` re-points them | skip the `.rodata` segment when copying (`memcopy-rw`) |
| Struct layout edits (insert, swap fields) | corrupt / SIGSEGV unless guarded | corrupt unless guarded |
| Layout guard that worked | size + field offsets from a live instance | source offsets **and** link-map fingerprint (the optimizer split the static struct) |
| Correct for every edit tested | `snapshot`, `auto` | `snapshot`, `auto` |
| Swap time | ≈ 0.1 ms (mostly `dlopen`) | ≈ 0.5 ms p50, ≤ 1.5 ms p95 |
| Edit → swap (hot compile) | 1.08 s median, 3.29 s max (`mojo build` ≈ 0.98 s of it) | not measured end to end; build 0.22–0.34 s + swap 1–3 ms in the browser e2e |
| Rebuild time | 1.1 s median (`mojo build --emit shared-lib`) | ≈ 0.2–0.3 s (clang → llc → wasm-ld, C stand-in) |
| Target-specific trap | `dlopen` of an already-loaded path returns the old library | memory copy cost grows ~1 ms/MiB |

The Mojo → wasm path itself is still gated on Mojo emitting LLVM IR for a
whole module (see [STATUS.md](../../STATUS.md)). Until then the wasm phase uses
the C stand-in, so its rebuild time is not comparable to a real Mojo rebuild.
