# Hot reload in other languages: mechanisms and usage

How 14 existing systems implement hot reload and how developers use them,
compared with what this experiment measured (native Mojo `.so`, wasm). Every
claim cites a primary source (official docs or the project's own repo), read
on 2026-09-30. Sources are listed at the end.

## 1. Four implementation families

| Family | What is replaced | Where the state is | Systems |
|---|---|---|---|
| **A. Swap the module, state lives outside it** | the whole code module (DLL / `.so` / wasm instance) | memory owned by the host, or a declared state section copied across | Handmade Hero, cr.h; this repo's native `rebind`, wasm `memcopy` |
| **B. Patch code inside the running process** | individual functions or methods | untouched: heap, statics and objects stay where they are | Live++ / Unreal Live Coding, .NET Hot Reload, JVM HotSwap, Dart VM (Flutter), Subsecond (Rust), Erlang code loading |
| **C. Re-run the module, carry state through hooks** | the module is re-executed | whatever the hooks keep | Vite HMR, React Fast Refresh, Python `importlib.reload`, Unity domain reload |
| **D. Explicit data migration on a layout change** | the data itself | converted by a user function | Erlang `code_change/3`, Common Lisp `update-instance-for-redefined-class`, Live++ pre/post-patch hooks, Unreal "Reinstancing"; this repo's `snapshot` |

Family D is not an alternative to A–C. Every system that allows layout changes
falls back to it, and systems that lack it forbid those changes (JVM,
Subsecond) or restart (Flutter hot restart, .NET "rude edits").

## 2. Per system

### A. Swap the module

**Handmade Hero (C, Windows), day 21.** Game code is a DLL and the platform
executable owns the game memory. The DLL is copied to a temporary name before
loading, so it can be rebuilt while loaded. `local_persist` (static) variables
were moved out of the DLL into `game_state`, so they survive a reload. [HH21]
- Same as this repo's native design: the host owns the state block, and each
  build is loaded from a new path.

**cr.h (C/C++, single header).**
- **State:** carried two ways: globals tagged `CR_STATE` go into a separate
  section that cr.h copies across, and a `void *userdata` pointer is passed
  between versions.
- **Loading:** each build is copied to a versioned path (`game1.dll`,
  `game2.dll`, …).
- **Crash rollback:** SIGSEGV/SIGILL/SIGBUS are trapped
  (`sigsetjmp`/`siglongjmp` on Linux, SEH on Windows) and cr.h rolls back to
  `last_working_version`.
- **Callback ops:** `CR_LOAD`, `CR_STEP`, `CR_UNLOAD`, `CR_CLOSE`.
- **Caveat it documents:** "Avoid holding any pointer to static stuff". [CR]
- **Compared with this repo:** that caveat is the dangling `label` crash this
  experiment reproduced (native `close` → SIGSEGV). The versioned path matches
  finding 5. Rollback is something this repo does not have.

### B. Patch in place

**Live++ (C/C++) and Unreal Live Coding.**
- **Build requirements:** `/hotpatch` and `/FUNCTIONPADMIN`.
- **Patching:** compiles the changed code in the background and "loads the new
  code into your application, linking it against existing code".
- **State:** mutable globals and statics are preserved.
- **Layout changes:** "existing objects must have their data migrated from the
  old into the new memory layout", using pre-patch and post-patch hooks.
- **Hot-Restart:** restarts the process while keeping debug data and compiled
  patches. [LPP]
- **Unreal Live Coding** is "an integration of Live++". Without "Object
  Reinstancing", "new functions, new sets of variables, or dramatic
  re-factors … will usually result in crashes". It is not available on
  consoles or mobile. [UE]

**.NET Hot Reload (Edit and Continue).**
- **How:** Roslyn produces deltas that are applied to the running process,
  with or without the debugger on .NET 6+.
- **What changes take effect:** code runs in its new form only when it is
  executed again. `MetadataUpdateHandler` lets frameworks refresh, for example
  to re-render.
- **Unsupported edits:** the IDE offers "rebuild and apply changes (restart)",
  and "all application state is lost".
- **Build restrictions:** Debug builds only; trimming and ReadyToRun disable it. [NET]

**JVM HotSwap (`Instrumentation.redefineClasses`).**
- **What may change:** method bodies, the constant pool and attributes. It
  "must not add, remove or rename fields or methods, change the signatures of
  methods, change modifiers, or change inheritance" (later relaxed to allow
  private methods).
- **Active frames** keep running the old bytecode; new calls get the new code.
- **Instances and statics:** existing instances are not affected, and "The
  values of static variables will remain as they were". [JVM] [JDK]

**Dart VM / Flutter stateful hot reload.**
- **How:** changed libraries are compiled to kernel and injected into the VM.
- **What re-runs:** the framework rebuilds the widget tree (`build()` runs
  again); `main()` and `initState()` are not re-run.
- **Globals and statics** are "treated as state, and are therefore not
  reinitialized".
- **Unsupported:** changes between enum and class, and changes to generic type
  declarations. Hot restart discards the state. [DART]

**Subsecond (Rust; used by Dioxus `dx serve --hotpatch`).**
- **How:** calls go through a jump table of the latest function pointers.
  Only the changed code is compiled and linked against the existing addresses,
  and the new table is sent over websocket.
- **Active calls:** if code *above* a `subsecond::call` changes, it panics and
  unwinds to the nearest `call`.
- **Structs:** not hot-reloadable, because a layout change crashes.
- **Statics:** their destructors never run, and a renamed static counts as new.
- **Thread-locals** reset.
- **Platforms:** Linux, macOS, Windows, Android, iOS simulator, and wasm. [SUB]

**Erlang/BEAM code loading.**
- **Versions:** "current" and "old" versions of a module coexist. Loading a
  third version purges the old one and kills processes still running it.
- **Which calls switch:** fully qualified calls (`m:f()`) always run current
  code; local calls stay in the version they are in. [ERL]
- **Usage:** a long-running loop switches to new code when it makes a
  fully qualified call to itself.

### C. Re-run the module, keep state through hooks

**Vite HMR.**
- **Hooks:** `import.meta.hot.accept` marks a module as a boundary that
  accepts updates; `hot.dispose` cleans up side effects.
- **State:** `hot.data` "is persisted across successive instances of the same
  module".
- **Unaccepted updates** propagate to importers and end in a full page reload. [VITE]

**React Fast Refresh.**
- **State:** `useState` and `useRef` keep their values "as long as you don't
  change their arguments or the order of the Hook calls".
- **Always re-run:** `useEffect`, `useMemo` and `useCallback`.
- **Scope of an edit:** editing a non-component module re-runs its importers;
  editing a file imported outside the React tree causes a full reload.
- **Opt-out:** `// @refresh reset` forces a remount. [RN]

**Python `importlib.reload`.**
- **Re-runs module code:** the module's top-level code runs again, but the
  module dictionary is retained, so a deleted name keeps its old value.
- **Not updated:** instances keep the old class, and names bound with
  `from … import` elsewhere keep the old objects.
- **Not thread-safe.** [PY]

**Unity domain reload.** The Mono scripting state is reset: static fields and
static events return to their initial state, and serializable objects go
through serialize → reload → deserialize. Domain reload can be disabled when
entering Play mode for speed, but then statics keep their values and have to
be reset by hand (`[OnEnteringPlayMode]`, `[AutoStaticsCleanup]`). [UNITY]
- Same as this repo's `snapshot`, applied to the whole scripting domain.

### D. Migration functions

**Erlang `gen_server:code_change(OldVsn, State, Extra)`.** Called during a
release upgrade or downgrade. It receives the old version and the old state,
and "must return the updated internal state"; returning `{error, Reason}`
aborts the upgrade. [GEN]

**Common Lisp `update-instance-for-redefined-class`.** After a class is
redefined, existing instances are updated through this function, which
receives:
- the added slots;
- the discarded slots;
- a property list of the discarded slots' values, so the method can convert
  them, for example between coordinate systems. [CLHS]

### No unloading at all

**Go `plugin`.** "A plugin is only initialized once, and cannot be closed."
Supported only on Linux, FreeBSD and macOS. The host and plugins must be built
with the same toolchain, build tags, flags and dependency sources. [GO]

## 3. How developers use them

| System | Trigger | State after the reload | Where it is used |
|---|---|---|---|
| Flutter | IDE shortcut (⌘\) or `r` in `flutter run` | kept; widget tree rebuilt | development |
| Vite / React | on save, automatic | kept where hooks allow | development |
| .NET | Alt+F10 / Hot Reload button, or automatic with `dotnet watch` | kept; restart on unsupported edits | development |
| Unreal Live Coding | in-editor compile | kept, with Reinstancing | development (editor, PIE, desktop) |
| Live++ | shortcut in the running app | kept; migration via hooks | development |
| Subsecond | `dx serve --hotpatch` | kept, except struct layout changes | development |
| cr.h / Handmade Hero | rebuild; the host polls the file timestamp | kept (host-owned memory) | development |
| Erlang/OTP | release upgrade (`appup`/`relup`), or `l(Module)` in the shell | converted by `code_change/3` | **production**, not just development |
| JVM HotSwap | debugger or agent | kept; only method bodies change | development, agents |

Only Erlang ships hot code loading as a production deployment mechanism. The
rest target the edit–run loop.

## 4. The same problems, compared

| Problem | This repo measured | How others handle it |
|---|---|---|
| Pointers into the old module's static data | native: SIGSEGV after unload; wasm: stale `.rodata` | cr.h: "Avoid holding any pointer to static stuff"; Handmade Hero moves statics into `game_state` |
| Static initializers not re-run | wasm `memcopy` kept old data | Dart, JVM and Python all keep statics/globals as state; Unity resets them all (domain reload) |
| Rebuilding while the old binary is loaded | `dlopen` of the same path returns the old library | cr.h versioned paths; Handmade Hero temp copy |
| Struct layout change | in-place swap corrupts or SIGSEGVs; `snapshot` is correct | JVM, Subsecond and Flutter forbid it; Live++, Unreal, Erlang and CL migrate explicitly |
| Code still running in the old version | not reached: the swap happens between frames | JVM and Erlang let old frames finish on old code; Subsecond unwinds to the nearest `call` |
| New build crashes | not handled: the host dies | cr.h traps the signal and rolls back to `last_working_version` |
| Compile time dominates | `mojo build` ≈ 1 s of the 1.08 s edit → swap | Zig incremental: 14 s full build → 63 ms per edit with `--watch` on a 500k-line project (0.14), still experimental in 0.15 [ZIG14] [ZIG15]; Live++ and Subsecond compile only the changed code |
| Unloading | works: 5 mappings → 0 | Go cannot unload plugins at all |

## 5. What this suggests for LudensEngine (proposals, not yet tested)

1. **Crash rollback (from cr.h).** Run the first frames of a new version under
   a SIGSEGV handler; on a crash, return to the last good build. The state
   block must be copied before handing it over, or `rebind` has nothing to
   roll back to. Test: an edit that dereferences null in `engine_update`.
2. **Versioned migration (from Erlang `code_change` and CL
   `update-instance-for-redefined-class`).** Pass the old schema version to
   `engine_load`, and write snapshots with dev's reflection schemas
   (`ecs/schema.mojo`) instead of the hand-written word layout. Added and
   removed fields then become visible to the migration, like CL's
   added/discarded slots.
3. **No static pointers in state (Handmade Hero, cr.h).** Store an index
   instead of a `StaticString` in `EngineState`. That removes the need for
   `engine_rebind`, which today has no automatic check.
4. **Function-level patching (Live++, Subsecond).** Swap functions instead of
   the whole `.so`. Mojo would need compiler and linker support for this;
   not feasible now, recorded for reference.
5. **Faster compiles.** The 1 s is `mojo build` of the whole engine `.so`.
   Splitting engine systems into several smaller `.so` files, so an edit
   rebuilds only one, needs a measurement before it is worth doing.

## Sources

- [HH21] Handmade Hero day 21, Loading Game Code Dynamically — https://guide.handmadehero.org/code/day021/
- [CR] fungos/cr — https://github.com/fungos/cr
- [LPP] Live++ documentation — https://liveplusplus.tech/docs/documentation.html
- [UE] Unreal Engine, Live Coding — https://dev.epicgames.com/documentation/en-us/unreal-engine/using-live-coding-to-recompile-unreal-engine-applications-at-runtime
- [NET] Visual Studio Hot Reload — https://learn.microsoft.com/en-us/visualstudio/debugger/hot-reload
- [JVM] `java.lang.instrument.Instrumentation` (Java 21) — https://docs.oracle.com/en/java/javase/21/docs/api/java.instrument/java/lang/instrument/Instrumentation.html
- [JDK] JDK-8192936, RedefineClasses spec vs. implementation (private methods) — https://bugs.java.com/bugdatabase/view_bug.do?bug_id=8192936
- [DART] Flutter hot reload — https://docs.flutter.dev/tools/hot-reload
- [SUB] Subsecond crate docs — https://docs.rs/subsecond/latest/subsecond/
- [ERL] Erlang code loading — https://www.erlang.org/doc/system/code_loading.html
- [GEN] Erlang `gen_server` — https://www.erlang.org/doc/apps/stdlib/gen_server.html
- [VITE] Vite HMR API — https://vite.dev/guide/api-hmr
- [RN] React Native Fast Refresh — https://reactnative.dev/docs/fast-refresh
- [PY] Python `importlib.reload` — https://docs.python.org/3/library/importlib.html
- [UNITY] Unity domain reloading — https://docs.unity3d.com/Manual/domain-reloading.html
- [CLHS] CLHS `update-instance-for-redefined-class` — https://www.lispworks.com/documentation/HyperSpec/Body/f_upda_1.htm
- [GO] Go `plugin` package — https://pkg.go.dev/plugin
- [ZIG14] Zig 0.14.0 release notes (incremental compilation) — https://ziglang.org/download/0.14.0/release-notes.html
- [ZIG15] Zig 0.15.1 release notes — https://ziglang.org/download/0.15.1/release-notes.html
