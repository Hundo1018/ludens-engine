# Automation contract (#115)

A game can be driven by a test or an agent with no person: read its state, press keys, step with or without drawing, start in
a given scene with a given seed, compare two runs tick by tick, and run many games headless for statistics. Four parts:

| part | where | runs on |
|---|---|---|
| `window.game` | `shell/web/game_hook.mjs`, wired in `shell/web/app.ts` | the page, and node with no WebGPU (`scripts/game_run.mjs`) |
| URL parameters `?seed=` `?scene=` `?manual` | `shell/web/app.ts` | the page |
| divergence trace | `scripts/divergence.py` | node, wasm64 |
| batch runner `ludens sim` | `scripts/sim_batch.py`, `game/batch.mojo`, `app/sim_main.mojo` | native, no GPU |

Checks: `pixi run -e wasm test-automation` (hook, trace, batch runner, 36 checks) and `pixi run -e wasm hook-web` (the same
hook in headless Chrome).

## `GameMode` additions (`game/mode.mojo`)

| method | meaning | default |
|---|---|---|
| `state(self) -> String` | the game's state as one JSON object | `{"hash":"<hash()>"}` |
| `reset(mut self, seed: UInt64, scene: String) raises -> Bool` | start over in a scene ("" = the default) with a seed (0 = the fixed layout); raise for an unknown scene | returns `False`: "no seeds or scenes" |

A game that overrides neither still runs, and the hook reads its hash. `?seed=` or `?scene=` on such a game is an error
(`configure` throws "this game has no seeds or scenes"), not silently ignored. `state()` should print numbers with `String(Float64)`
so equal states give equal text; the divergence tool flattens nested objects and arrays to paths such as `ball.pos[1]`.

The demo game (`game/demo_mode.mojo`) implements both. `state()` has `tick`, `jumps`, `paused`, `seed`, `scene`, `yaw`,
`ball.pos`, `ball.vel`, `crates` (positions) and `hash`. Scenes: `arena` (the default: pillars and three crates) and `bare` (floor
and ball). A seed other than 0 moves each crate by up to 0.6 m in x and 0.4 m in z and the ball's start by up to 0.5 m in x, drawn from
one `SplitMix64` stream; seed 0 draws nothing, so a run with no seed has the same hash as before this change.

## `window.game`

| call | |
|---|---|
| `state()` | the game's `state()` parsed |
| `press(key)` | a tap: key down and up inside one frame. The game sees the press edge (jump, pause, restart), not a held key |
| `hold(key)` / `release(key)` | key down until released; use for movement. `releaseAll()` lets go of every key |
| `step(n = 1, draw = true)` | `n` frames of 1/60 s; returns the hash. `draw = false` steps with no drawing and no presenting (`app_step`): the network is read, the game steps, the key edges of the frame end. It does not need the GPU |
| `hash()` | the state hash as a decimal string (a u64 does not fit a JS number) |
| `events()` | sound cues raised since the last call: `[{"frame": N, "cue": C}]`, `N` counting game frames since the game started; clears the list |
| `configure(seed, scene)` | start over; what `?seed=` and `?scene=` call |
| `axis(device, axis, v)` / `padButton(device, b, down)` | an analog axis or a gamepad / on-screen button (`docs/input.md`) |
| `rebind(line)` / `resetBindings()` / `prompt(action, device)` | change and read the action bindings; `rebind` returns `{ok}` or `{ok: false, conflicts}` and saves the profile |
| `console(line)` / `consoleLog()` / `consoleReplay(log)` / `cheated()` | the in-game console (docs/console.md): a line as if typed (returns what it prints, throws for a refused line), the log as `frame line` lines, a log to play back, whether the run used a cheat |
| `photo(on)` / `photoSet(name, v)` / `photoMove(f, r, u, s)` / `photoCapture()` | photo mode (docs/console.md): enter or leave, set `focus`, `fstop`, `exposure`, `bloom`, `scale` or `focal` (mm), fly the camera, capture a PNG with the next drawn frame |

A key is a DOM `KeyboardEvent.code` (`KeyW`, `Space`, `ArrowUp`, `Escape`) or a single letter or digit (`w`). One stepped frame is one
game tick for the demo game (`state().tick` equals the frames stepped; checked for 600 frames).

URL parameters: `?seed=N` (decimal), `?scene=NAME`, `?manual` (no animation loop: frames come only from `step`; no audio is
rendered). `?offscreen` still applies for headless Chrome. `?demo` and `?selftest` load the physics demo, which has no game:
`window.game` exists there but `state()` throws.

```js
// index.html?manual&seed=3&scene=arena
game.hold("KeyW");
game.step(300, false);
game.press("Space");
game.step(1);          // drawn
console.log(game.state().ball.pos, game.hash(), game.events());
```

## Under node

`scripts/game_run.mjs` loads `build/app.wasm`, makes the same hook and runs a job file (format at the top of that script):
ticks, seed, scene, and a key script such as `{"tick": 10, "hold": "KeyD"}`. It prints one JSON line per tick. A script entry at tick
`t` applies before step `t`, so it first shows in the line with tick `t + 1`.

## Divergence trace

```
pixi run -e wasm divergence record job.json -o a.jsonl
pixi run -e wasm divergence record job_with_a_change.json -o b.jsonl
pixi run -e wasm divergence diff a.jsonl b.jsonl
```

A trace line is `{"tick": N, "hash": "...", "state": {...}}`; tick 0 is the state before the first step. `diff` exits 1 and prints
the first tick whose hashes differ, then every state key that differs there with both values; it exits 0 for equal traces.
Example, a jump tap injected at tick 300 of a 600-tick run (`tests/test_automation.py`):

```
first difference at tick 301: hash ... against ...
8 state key(s) differ:
  ball.pos[0]: ... against ...
  ...
  jumps: 1 against 2
```

The tool compares what `state()` reports. If the hash covers something `state()` does not show, it says "no state key differs".

## Batch runner

```
pixi run -e wasm ludens sim demo --seeds 1..1000 --ticks 300 --hold W --jump-every 100 --report tick,jumps,ball.pos[0],hash
```

One row per seed (`seed` is always the first column), then min / mean / max of each numeric column. `--seeds` takes ranges and lists
(`1..1000`, `7`, `1,5,9`, `1..10,20..30`); `--report` takes `state()` paths; `--hold` keys among W A S D held for the whole run;
`--jump-every N` presses jump every N frames; `--scene` picks the scene. Numbers print with `%.6g`, so the same arguments give the same
bytes (`tests/golden/sim_demo_table.txt`).

The runner is `simulate[M: GameMode]` in `game/batch.mojo`. `app/sim_main.mojo` is the three-line entry for the demo game; a game in
another repository makes its own entry and adds it to `MODES` in `scripts/sim_batch.py`. The native binary is built the way the parity
gates build theirs (serial ludens-core, the wasm runtime's libm). A plain `mojo build` fuses multiply-adds and ends in different last
bits: seed 3 of the table above ended with hash 3649554443855854851 in that build and 5173417609619489773 in the wasm64 module.
With this build the rows equal the wasm64 hook's hashes (checked for seeds 1, 3, 11 and 16).

## Not covered

- ludens-playground's modes get the default `state()` (the hash) and `reset()` (unsupported) until they implement the two methods there.
- Only keys are scripted: no pointer, gamepad or touch events, no mouse look.
- The hook does not drive the physics demo (`?demo`), only a `GameMode`.
