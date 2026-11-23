# Input actions (#117)

A game reads actions (`jump`, `move`, `look`), never keys. The bindings are an asset; a player's changes are a separate, small
profile saved with the host's file storage and put over the defaults at start.

Code: `game/action_map.mojo` (map, rebinding, profile, input buffer), `game/controls.mojo` (the demo game's actions to its `Intent`),
`game/input_strings.mojo` (names of keys and buttons for prompts, as string tables), `app/controls.mojo` (`InputState` to `InputFrame`),
`app/profile.mojo` (profile through `os_file_*`), `shell/web/pad.ts` and `vpad.ts` (gamepad and on-screen pad events).
Asset: `game/data/demo.actions`, embedded in `game/demo_actions.mojo` by `scripts/gen_actions.py` (`pixi run -e wasm gen-actions`;
`lint` fails when the two differ).

## Action map format

```
ludens-actions 1
action move stick deadzone=0.2 curve=1.0
action look look
action jump button buffer_ms=100
bind move.up key:KeyW
bind move.x pad:a0
bind move.y -pad:a1
bind look mouse:drag0
bind jump key:Space
bind jump pad:b0
```

| kind | value | slots | attributes |
|---|---|---|---|
| `button` | `down`, `pressed` (one frame), `released` | `main` | `buffer_ms` 0..1000 |
| `stick` | `x` right, `y` forward, each -1..1 | `up down left right` (keys, buttons), `x y` (axes) | `deadzone` 0..<1, `curve` > 0 |
| `look` | `x`, `y` in pixels | `main` | none |

Sources are `device:code`. A leading `-` negates an axis (`-pad:a1`: the Gamepad API's y is down, a stick's forward is up).

| source | meaning |
|---|---|
| `key:KeyW`, `key:Space`, `key:ArrowUp` | a key, by DOM `KeyboardEvent.code` |
| `mouse:0`, `mouse:drag0` | a mouse button; pointer movement while that button is held (`look` only) |
| `pad:b0`, `pad:a0` | a button or axis of any gamepad (W3C standard mapping) |
| `vpad:b0`, `vpad:a0` | the same numbering on the on-screen pad (`shell/web/vpad.ts`) |

Errors name the line: `3: `Banana` is not a key name; use a DOM KeyboardEvent.code such as KeyW, Space, ArrowUp`.

## Wire format from the shell

| input | `app_input(kind, key, action, mods, x, y)` |
|---|---|
| keyboard | `KEY`, GLFW code, down / up |
| gamepad or on-screen pad button `b` of device `d` | `KEY`, code `400 + 20 d + b` (devices 0 to 2 gamepads, 3 on-screen pad) |
| axis `a` of device `d` | `AXIS` (5), `key = a`, `action = d`, `x = value` (wgpu-mojo `InputState.get_axis(d, a)`) |

Gamepad buttons are key codes so a press has an edge for free. Gamepads past index 2 are ignored.

## Analog sticks

A stick's analog vector `v` (length 1 is full travel, y forward) is shaped by the action's radial dead zone and response curve:
`m = |v|` clamped to 1; `m <= deadzone` gives 0; otherwise the length becomes `((m - deadzone) / (1 - deadzone)) ^ curve`,
direction unchanged. Keys give the unit steps -1, 0, 1 as before (W and D together are (1, 1), not normalised). The result is the larger of
the digital and analog vectors, so a keyboard and a pad do not add. The on-screen pad's stick is sent raw (`dead: 0` in
`DEFAULT_PAD`); the map's dead zone is the only one.

## Physical keys

A binding names the key's position, the DOM `code`. On an AZERTY keyboard the key labelled Z sits where QWERTY has W and the
browser reports `code = "KeyW"`, so `key:KeyW` moves forward on both. `shell/web/keys.ts` converts `code`, never `key`.

## Rebinding and the profile

`ActionMap.rebind(action, slot, binding, take)` replaces what the slot had on the binding's device (the gamepad bindings of
`jump` stay when its key changes). It returns the slots that already use the control (`move.up`, `jump.main`): with `take` False nothing
changes; with `take` True the control is removed from them. A key on a slot of another kind (a key on `move.x`) raises.

The profile lists only the slots that differ from the defaults, sources sorted:

```
ludens-profile 1
set jump.main key:KeyJ pad:b0 vpad:b0
```

`load_profile(text)` applies the rows it can and returns the ones it skipped (unknown action, slot or source, a control another slot
holds). The app writes `profile/actions.txt` after every rebind and requests it on its first frame; the result arrives through `os_poll`
within a frame or two.

`window.game` (docs/automation.md): `rebind("jump key:KeyJ")`, `rebind("move.up key:KeyI take")`, `resetBindings()`, `prompt("jump", "gamepad")`,
`axis(device, axis, value)`, `padButton(device, button, down)`. Exports: `app_rebind`, `app_bindings_reset`, `app_prompt`, `app_text_len`.

## Input buffer

`buffer_ms` on a button is passed to the game as `Intent.jump_buffer_ms` (for `jump`). The game keeps an `InputBuffer`: `press(window)`
when `Intent.jump` arrives, `take()` where the action can happen (it answers once), `age(dt_ms)` once per frame. The demo game
(`game/demo_mode.mojo`) buffers its jump: with `buffer_ms=100` a press in the 5 frames (60 Hz) before landing jumps on landing.
Its hash includes a pending press.

## Prompts

`prompt_text(map, loc, action, slot, device)` returns the name of the control that does the action on a device (`DEV_KEY`, `DEV_MOUSE`,
`DEV_PAD`, `DEV_VPAD`), "" when that device has none. Names come from `input_localizer()` (en and zh-TW; keys such as `input.key.space`,
`input.pad.b0`). The shell can fill `ActionMap.key_labels` with `"KeyW=Z"` pairs (from `navigator.keyboard.getLayoutMap()`) so an
AZERTY player sees Z; the shell does not do that yet.

## Not done here

- Contexts (menu, gameplay) with different maps; swap on conflict; hold and double-tap triggers; a rebinding screen.
- The HUD hint (`hud.hint`) is still a fixed string; it does not use `prompt_text` yet.
- Gamepad right stick still turns the camera as a virtual mouse drag in `shell/web/app.ts`, not as an axis of `look`.
- Gamepad rumble, device hot-plug names, `navigator.keyboard.getLayoutMap()`.

## Checks

`pixi run -e wasm test-game` (`tests/action_map.mojo`, `game_controls`, `input_path`, `demo_mode`), `test-pad`, `test-vpad`, `test-input`
(`tests/test_input.mjs`: the wasm64 app under node, axes, rebinding, profile restored by a second instance on the same storage).
