# Exit-time SIGSEGV after unloading a Mojo shared library that touched a stdlib global

## Problem

A Mojo executable loads a Mojo shared library, the library calls
`std.random.random_ui64`, the executable `dlclose`s the library, and then
`main` returns. The process dies with SIGSEGV inside
`KGEN_CompilerRT_DestroyGlobals`.

```
$ python3 experiments/upstream_probes/run.py <mojo>
plugin used std.random, unloaded: exit (5 runs)     predicted=SIGSEGV  observed=SIGSEGV  ok
plugin used std.random, kept loaded: exit (5 runs)  predicted=0        observed=0        ok
```

Reproduced 5/5 on Mojo 1.1.0 (8189361e) and on nightly 1.2.0.dev2026093005
(b3556108), Linux x86-64. The control keeps a second handle to the same
library open, so its code is still mapped at exit. It exits 0 in 5/5 runs.

gdb backtrace of the failing run:

```
#0  0x00007ffff7e74280 in ?? ()          <- address inside the unloaded library
#1  ... in libKGENCompilerRTShared.so
#2  ... in KGEN_CompilerRT_DestroyGlobals () from libKGENCompilerRTShared.so
#3  ... in main ()
```

## Cause

`std.random` keeps its state in `_Global["random_state", ...]`
(`stdlib/std/random/_rng.mojo:284`). The first module that touches it
registers its own copy of `_Global._deinit_wrapper` as the entry's
`destroyFn` (`Support/lib/ADT/GlobalTable.cpp`, `getOrCreate`). The
entry outlives that module. `_startup.mojo:75` calls
`KGEN_CompilerRT_DestroyGlobals` after `main`, and that calls a
`destroyFn` whose code has been unmapped.

The same happens with any stdlib `_Global`: `random_state`,
`IS_STDOUT_TTY` (`utils/_ansi.mojo`), the Python globals
(`python/python.mojo`, `python/bindings.mojo`), and user code that uses
`_Global` directly (`host_swap_global.mojo` in the same directory).

Python hosts do not crash, because they never call `DestroyGlobals`.

## Who is affected

Any Mojo executable that unloads a Mojo shared library before it exits:
plugin hosts, hot-reload loops, and tools that build variants as shared
libraries, load them, and unload them (for example a benchmark or autotuning
loop). The library does not need to use a private API: calling `std.random`
is enough.

## Possible fixes

All three are confined to CompilerRT and `Support/ADT/GlobalTable`. None
changes language semantics, IR semantics, or the compilation pipeline.

1. **Skip destroy functions whose module is gone.** When an entry is
   created, record `dladdr(destroyFn)` (base address and file name). At
   `DestroyGlobals`, call the function only if `dladdr` still resolves it to
   the same object; otherwise leak the value, since the process is exiting.
   This touches `GlobalTable.h/.cpp` (one field, or a predicate passed to
   `clear()`) and `Globals.cpp`. The cost is one `dladdr` per global creation
   and one per global at exit.
2. **Last registrant wins.** Update `destroyFn` on every `getOrCreate` hit.
   This fixes the hot-reload order (the newest module is alive) but not a
   plugin that is loaded after the host touched the global and unloaded later.
3. **Per-module teardown**, like glibc's `__cxa_finalize` at `dlclose`. Each
   Mojo shared library would unregister its entries from a destructor. This
   is the most complete fix, but it needs codegen changes, so it is outside
   the "bug fixes only" scope.

Option 1 is the smallest change that covers both repro cases.

## Test to add

A `Mojo/test/mojo-integration` case built from `plugin_rand.mojo` and
`host_rand.mojo`: the unloaded run must exit 0.

## Before filing

- Search the tracker for duplicates. This session could not reach GitHub
  search.
- Upstream's `AI_TOOL_POLICY.md` asks for a human-written description and
  an `Assisted-by: AI` label.
