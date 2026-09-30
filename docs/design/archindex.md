# Spec: tools/archindex.mojo (ROADMAP 17.0a, ARCHITECTURE.md §4–§5)

## Why
User's point 5: an automated architecture index with fewer false positives / errors and fewer
tokens than grep. Also the machine gate for points 1 (layers/cycles/reach-through) and 4 (tiers).
User directive: implement in Mojo using Mojo features; Python only via Mojo interop where Mojo
stdlib lacks the facility (JSON/TOML parsing, launching `mojo doc`).

## Sources (exact, not textual guesses)
1. `mojo doc -I build <pkg> -o build/archdoc/<pkg>.json` for every engine package (the dirs listed
   in scripts/arch_layers.toml [layers] that exist on disk + harness). Gives every struct / trait /
   function / comptime alias with signature, `raises`, `parentTraits`, fields, methods (no line numbers).
2. Import statements of every `.mojo` under engine packages + tests/ benchmarks/ examples/
   experiments/ tools/: `from X import a, b as c, (...)` (incl. multi-line parenthesised) and
   `import X`; relative `from .m import` resolved against the file's package. Only import
   STATEMENTS are parsed (skip docstrings and comments: track triple-quoted string state).
3. Line numbers: for a decl found by (1) in module file F, the line is the first line of F matching
   `^\s*(struct|trait|def|comptime)\s+NAME\b` (methods: first `def NAME` after their struct's line).
   Search is confined to the declaring file → no cross-file false positives.

## Commands  (`pixi run arch -- <cmd>`; wrapper scripts/arch.sh rebuilds build/archindex
##           only when tools/archindex.mojo is newer than the binary)
- `build`            regenerate build/archindex.json (auto when any *.mojo is newer than the json)
- `def NAME`         `path:line  kind  signature` for every declaration named NAME (exact; `--prefix`)
- `impl TRAIT`       every struct whose parentTraits contain TRAIT = every variant on that seam
- `uses TARGET`      importers of a module (`collision.queries`) or of a symbol (`SceneQuery`), path:line
- `deps MODULE`      direct imports (`--all` transitive), grouped by package
- `raises PKG`       functions/methods with raises=true in PKG (error-policy audit)
- `summary [PKG]`    per package: layer, modules, LOC, public structs/traits count, fan-in/fan-out
                     — ≤60 lines for the whole engine; the cold-start orientation a new agent reads
- `check`            exit 1 + list on: (a) import of a package with layer >= own layer (except self);
                     (b) engine package importing an [infrastructure] package; (c) module-level cycle
                     (Tarjan SCC, report each SCC); (d) cross-package import of a `_`-prefixed name
                     not in [allow_private]; (e) engine package dir missing from [layers].
                     Prints `arch check: OK (<n> modules, <m> edges)` on success.
- `tiers`            for each tests/test_*.mojo: declared `# tier:` header (or MISSING) and the
                     computed span = set of engine packages reached transitively from the test's
                     imports (excluding diag/harness; geometry counted only if a non-geometry package
                     is absent). Suggested tier: 1 package & 1 module under test → unit; 1 package
                     multiple modules or a trait with ≥2 impls exercised → component; ≥2 packages →
                     integration; imports scheduler.gameloop + ecs + physics → system; file name
                     `test_stress_*` → stress. `tiers --check` exits 1 on missing/invalid headers.
- `bench`            fixed query set (≥10 queries covering def/impl/uses/deps). For each: the grep a
                     human/agent would run (`git grep -n -w NAME`, `git grep -n "import.*mod"`...),
                     its hit count + output bytes; the index answer's count + bytes; false positives =
                     grep hits not in the index answer; false negatives = index answers grep missed.
                     Prints a markdown table → pasted into docs/ARCHITECTURE.md §5.

## Mojo features to use (not decoration — where they are the natural expression)
- structs + `Writable` for records; `Dict`/`List`/`Set`; comptime constants for the tier names;
  a trait `Check` with one struct per rule (a,b,c,d,e) so rules are a seam iterated at comptime
  (`comptime for`) — adding a rule = adding a struct.
- Tarjan SCC iterative (no recursion depth issue) over `List[List[Int]]` adjacency.
- `std.os` / `std.pathlib` for walking and reading files if available (probe); Python interop
  (`Python.import_module("json"|"tomllib"|"subprocess")`) only for JSON/TOML/subprocess.

## Tests (定律 v3: ordinary / integration / extreme)
tests/test_archindex.* is awkward for a tool; instead `archindex selftest` builds a fixture tree
under a temp dir (fixture files written by the tool itself) containing: a clean layered pair, an
upward import, a same-layer import, a 3-module cycle, a private cross-package import, an allowed
private import, a multi-line parenthesised import, an import inside a docstring (must be ignored),
a relative import, a package missing from the layer table → asserts each is detected exactly once
and the clean ones are not. `pixi run arch -- selftest` must print `archindex selftest: N/N`.
Wire: `pixi run test` depends on `arch-check` (which runs `check` and `tiers --check`).

## Acceptance
1. `pixi run arch -- selftest` → all pass (paste).
2. `pixi run arch -- check` on the real tree → exactly one violation today:
   collision/bp_bvh.mojo:5 private `_Leaf` (then fix it per audit F9: call `BVH.build_boxes`, make
   the `_Leaf`-typed `build` overload private or accept it via allow_private with reason) → OK.
3. `pixi run arch -- def ContactScene6`, `impl BroadPhase`, `uses collision.queries`,
   `raises physics`, `summary` each produce correct output (spot-verify 2 answers by Read).
4. `pixi run arch -- bench` table produced; numbers pasted into ARCHITECTURE.md §5 with the
   reproduction command.
5. 0 warnings when building the tool.
