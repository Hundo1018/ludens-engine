# In-game console, cheats and photo mode (#146)

Three parts, each usable without the others:

| part | file | runs in |
|---|---|---|
| console: commands, cvars, line editor, log and replay | `game/console.mojo` | debug builds only (see below) |
| cheats and the cheated mark | `game/cheats.mojo`, `platform/achievements.mojo` (`CheatGuard`) | wherever the console is |
| photo mode: free camera, lens and picture settings, capture size | `game/photo_camera.mojo` (no GPU), `app/photo.mojo` (pipeline and capture), `platform/png.mojo` | every build |

## Console

The backquote key opens and closes it. While it is open the keys type into it and the game gets an idle intent. Enter runs the
line; Backspace deletes a character. The editor accepts letters (lower case), digits, space, minus and full stop.

A game offers commands and cvars through `GameMode.console_commands()` (game/mode.mojo): a list of `CommandSpec`, a command with
a usage line and a number of arguments, or a cvar with a type (int or float), a default and bounds. The host registers them once,
together with its own `photo.*` cvars. `help` lists every name; a cheat has a star.

`Console.submit(line, frame)` checks the line against the specs and queues it. It refuses, with the reason, an unknown name, a
wrong number of arguments, a cvar value that is not a number, not whole for an int cvar, or outside the bounds. A refused line is
neither queued nor logged. Nothing touches the game in `submit`: at the start of the next game frame the host takes the queue and
hands each line to `GameMode.run_command` before `step`. A cvar's new value is applied when the queue is taken.

### Replay

Every accepted line is logged with the game frame it was submitted in. `log_text()` writes `frame line` per line, e.g.

```
30 teleport 0 3 -4
40 god
50 spawn crate
```

`load_replay(text)` reads such a log back; before each game frame the host calls `due(frame)`, which submits that frame's lines
as if typed. With the same inputs the replayed run reaches the same state as the run that typed them:

- native, `tests/console.mojo`: 240 frames with five cheats typed; the log played into a fresh game gives the same hash
  (1367832950515764552) and logs the same lines; the run without the cheats ends at 10686208484115723779.
- wasm64 under node, `scripts/test_console_web.py`: the same five lines through `window.game.console`, then the log through
  `consoleReplay`: equal hashes at all 240 ticks (final 16804635493103759573), against 9642367829935838607 without the lines.
  The keyboard path is checked too: backquote, `g`, `o`, `d`, Enter at ticks 30 to 34 logs `34 god` and marks the run.

The log is part of what a replay needs, next to the inputs: the key script of `scripts/game_run.mjs` takes `"console"` entries and
a `"replay"` log (docs/automation.md). Lines typed while photo mode is on run before the frame photo mode returns to, so they replay
at the same frame.

### Release builds

`CONSOLE_BUILT` is `not is_defined["LUDENS_RELEASE"]()`. Every method body of `Console` is inside `comptime if CONSOLE_BUILT`,
so a build with `-D LUDENS_RELEASE` has no parser, no command table and none of the console's strings: `submit` and `due` do
nothing, `toggle` keeps it closed, `take` returns nothing.

- `ludens build` (the default `--config release`, also what `build-pages` publishes) passes `LUDENS_CONFIG=release` to
  `scripts/build_wasm.sh`, which adds the define. `build-wasm` on its own, and `ludens build --config debug`, keep the console.
- `scripts/test_console.py` builds `tests/console_release.mojo` both ways and looks for three strings of the console
  (`unknown command`, `is registered twice`, `console replay line`): all three are in the debug binary, none in the release
  binary (155 296 bytes against 21 648 bytes). `scripts/test_console_web.py` does the same for `build/app.wasm` against a
  release `build/app_release.wasm`.

## Cheats

`cheat_commands()` gives four specs with `cheat=True`: `god`, `noclip`, `spawn [crate]`, `teleport x y z`. What they do is the
game's. In the demo game (no health, no damage):

| command | effect in game/demo_mode.mojo | measured in tests/console.mojo |
|---|---|---|
| `god` | jumps work in the air (the ground check is the ball's only limit) | 5 jumps against 2 for the same presses |
| `noclip` | the ball's collision mask is 0 and it moves at a fixed height along the intent | height 1.5 m unchanged over 90 frames, 7.8 m travelled |
| `spawn [crate]` | a crate 2 m ahead of the ball, 1 m up (at most 64) | 10 bodies against 9 |
| `teleport x y z` | the ball to x y z, at rest | part of the replay run |

`CheatMark` (game/cheats.mojo) is what the game keeps: `marked`, `god`, `noclip`. `marked` is set by the first cheat and never
cleared in the run (a restart turns `god` and `noclip` off and keeps the mark). The demo writes `CheatMark.bits()` and the spawned
crate count into its save (version 3, docs/save-games.md), so a game loaded from a save made after a cheat is marked again, with the
same hash, and `noclip` is set on the ball again (`set_layer` is not part of the world blob).

The host reads `GameMode.cheated()` after running the console's lines and marks its `CheatGuard[LocalAchievements]`
(platform/achievements.mojo): from then on `unlock` and `set_stat` return `REQ_CHEATED` and reach no backend; reads still answer.
`app_cheated` / `window.game.cheated()` report the mark. A run with no cheat has the same `state()` text and the same hash as before
this change: the mark is added to both only when it is not clear.

## Photo mode

F9 enters and leaves it. While it is on:

- the host does not call `GameMode.step`: the game stands still. Under node, photo mode from tick 100 to 150 kept one hash over
  those 51 ticks (`scripts/test_console_web.py`).
- the camera is `PhotoMode.pose()`: it starts at the game's camera and flies with the intent (W A S D along the view, E / Q up and
  down, pointer drag to look; 4 m/s). It stays within 12 m of where it started and above the floor height (0.05 m, or the camera's
  start if that is lower); pitch is limited to 1.5 rad.
- the lens has a focal length in mm (`game/zoom_lens.mojo`). It starts at the focal length of the game camera's field on a
  24 mm sensor (fov_y 1.0 rad is 22.0 mm) and stays between 12 and 300 mm. Holding Z zooms in and X zooms out, 1.5 stops (doublings
  of the focal length) a second; the cvar `photo.focal` (or `photoSet("focal", mm)`) sets a target, which the lens reaches on a log
  scale: 63 % of the remaining ratio every 0.25 s. The field of view follows the focal length, and so does the depth-of-field blur,
  since app/lens.mojo computes its f from the field. Looking around turns by 0.004 rad per pixel times the field over the field at
  entry, so at 4 times the focal length the pointer turns the view a quarter as fast.
- the HUD is not drawn (the console still is, when open). In headless Chrome the photo frame differs from the paused frame where
  the pause banner and the counters were (`scripts/game_screenshot.mjs`).
- the frame is drawn by a second renderer with `PhotoPost`: depth of field, bloom, then exposure (app/photo.mojo). The settings are
  the cvars `photo.focus` (m), `photo.fstop` (0 = pinhole, else 1 to 32), `photo.exposure` (EV, -4 to 4), `photo.bloom` (0 to 4),
  `photo.scale` (1 to 8) and `photo.focal` (mm, 12 to 300), or `app_photo_set` / `window.game.photoSet`. The game's own post stages are not part of the photo
  pipeline.
- F8 (or `app_photo_capture`) draws the next frame again at the capture size (the window times `photo.scale`, 2 by default; a side
  is kept at most 8192 with the proportions) into a texture of its own, reads it back and encodes a PNG (platform/png.mojo). The
  page takes it with `app_take_photo` and offers it as a download.

Measured on lavapipe, `tests/photo_native.mojo` (640 x 360):

| check | result |
|---|---|
| photo pipeline at its defaults against the plain pipeline | 0 pixels differ |
| +1 EV | every channel below 127 doubled exactly (340 140 channels, largest error 0) |
| f/1 focused at 8 m, the edge of a box at 3 m | 6 px wide, 0 px without depth of field |
| bloom 1.0 at threshold 0.5 | frame sum 101 691 850 against 82 110 854 |
| capture at scale 2 | 1280 x 720 PNG, 31 392 bytes, decoded by Pillow |

`platform/png.mojo` writes 8-bit RGB with the Sub filter and fixed-Huffman deflate whose only match is a run of the pixel to the
left. It is exact (Pillow decodes the three test pictures of `tests/platform_png.mojo` to the bytes they were made from) but not
small: the 256 x 128 test picture is 12 841 bytes.

## Not done

- No key binding screen for the console or photo keys: they are fixed (backquote, F9, F8, Z / X; `app/controls.mojo`).
- Photo mode has no on-screen panel for its settings; the console cvars and the hook set them.
- A game's own post stages are not drawn in photo mode.
- The demo game unlocks no achievements, so the guard has nothing to refuse there; `tests/console.mojo` drives it directly.

## Tests

| task | what |
|---|---|
| `pixi run -e wasm test-console` | `tests/console.mojo` (48 checks), the release build and its strings, `tests/platform_png.mojo` with Pillow |
| `pixi run -e wasm test-console-web` | the wasm64 module under node: typed and hook lines, replay, photo mode pause; the release module's strings |
| `pixi run -e wasm test-photo` | `tests/photo_native.mojo` on lavapipe |
| `pixi run -e wasm game-shot` | photo mode in headless Chrome: HUD hidden (26 295 pixels differ from the paused frame), a 1920 x 1080 PNG for the 960 x 540 canvas (84 126 bytes) |
