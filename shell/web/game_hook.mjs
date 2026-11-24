// The automation hook of the game: `window.game` in the page, the same object under node (scripts/game_run.mjs).
// Documented in docs/automation.md. It only calls the module's generic app_* exports; it knows no game.
//
//   state()          the game's state as an object (the JSON of GameMode.state)
//   press(key)       a tap: down and up inside one frame (the game sees the press edge, not a held key)
//   hold(key)        key down until release(key)
//   release(key)     key up;  releaseAll() lets go of everything
//   axis(device, axis, v)    set an analog axis (device 0..2 gamepad, 3 on-screen pad; axis 0 / 1 left stick x / y, y down): the AXIS event
//   padButton(device, b, down)   a gamepad or on-screen button (its key code is 400 + 20 * device + b)
//   rebind(line)     `jump key:KeyJ`, `move.up key:KeyI take`: {ok: true}, or {ok: false, conflicts: ["jump.main"]}; saved to the profile
//   resetBindings()  every action back to its default bindings
//   prompt(action, device)   the name to show for an action on a device ("keyboard", "mouse", "gamepad", "touch"): "Space", "A"
//   access(line)     one accessibility setting, `text_scale 150`, `volume.music 40`, `mono on` (docs/accessibility.md); throws for a bad key or value
//   accessText()     the settings that differ from the defaults as profile rows;  resetAccess() puts them all back
//   captionsLoad(text)   a caption track;  say(speaker, line, ms)   a dialogue line as a caption;  captions()   the strings up now
//   shake(trauma)    camera shake trauma 0..1;  shakeOffset()   [x, y] metres the camera is moved at the player's scale
//   step(n, draw)    n frames of 1/60 s; draw = false (default true) steps with no drawing and no presenting
//   hash()           the game state's hash, a decimal string (a u64 does not fit a JS number)
//   events()         the sound cues raised since the last call: [{frame, cue}]
//   configure(seed, scene)   start the game over with a seed (a decimal string or integer) and a scene name
//
// A key is a DOM `KeyboardEvent.code` ("KeyW", "Space", "ArrowUp", "Escape", "Enter") or a single letter or digit ("w", "7").

export const DT = 1 / 60; // seconds per stepped frame: the demo game runs one fixed 60 Hz physics tick per frame at this dt
const KEY_EVENT = 1; // keys.ts EV.KEY
const DOWN = 1;
const UP = 0;
const AXIS_EVENT = 5; // keys.ts EV.AXIS: key = axis index, action = device, x = value
const PAD_BUTTON_BASE = 400, PAD_BUTTON_STRIDE = 20; // pad.ts
const DEVICES = { keyboard: 0, mouse: 1, gamepad: 2, touch: 3 };

// DOM code -> GLFW code, the table of keys.ts (that file is TypeScript, which node reads only with --experimental-strip-types
// and the page loads through build_web.py, so the hook takes `keyCode` from its caller instead of importing it).
export function createGameHook({ rt, app, keyCode }) {
  const code = (key) => {
    const dom = /^[a-zA-Z]$/.test(key) ? "Key" + key.toUpperCase() : /^[0-9]$/.test(key) ? "Digit" + key : key;
    const c = keyCode(dom);
    if (c < 0) throw new Error(`game: unknown key ${JSON.stringify(key)}`);
    return c;
  };
  const send = (k, action) => rt.call("app_input", app, KEY_EVENT, k, action, 0, 0, 0);
  const text = (n) => {
    if (n < 0) throw new Error("game: no game is running (app_set_mode / configure first)");
    return rt.str(rt.call("app_text_ptr", app), n);
  };
  const frames = (n, draw) => {
    if (!Number.isInteger(n) || n < 0) throw new Error(`game: step(n): n must be a non-negative integer, got ${n}`);
    for (let i = 0; i < n; i++) {
      const rc = rt.call(draw ? "app_frame" : "app_step", app, DT);
      if (rc < 0) throw new Error(`game: ${draw ? "app_frame" : "app_step"} failed (${rc}), see the console`);
    }
  };
  const hook = {
    state: () => JSON.parse(text(rt.call("app_state", app))),
    press(key) { const k = code(key); send(k, DOWN); send(k, UP); },
    hold(key) { send(code(key), DOWN); },
    release(key) { send(code(key), UP); },
    releaseAll() { rt.call("app_release_input", app); },
    axis(device, axis, value) {
      if (!Number.isInteger(device) || device < 0 || device > 3 || !Number.isInteger(axis) || axis < 0 || axis > 7) throw new Error(`game: axis(${device}, ${axis}): device 0..3, axis 0..7`);
      rt.call("app_input", app, AXIS_EVENT, axis, device, 0, Number(value), 0);
    },
    padButton(device, button, down = true) {
      if (!Number.isInteger(device) || device < 0 || device > 3 || !Number.isInteger(button) || button < 0 || button >= PAD_BUTTON_STRIDE) throw new Error(`game: padButton(${device}, ${button}): device 0..3, button 0..${PAD_BUTTON_STRIDE - 1}`);
      send(PAD_BUTTON_BASE + PAD_BUTTON_STRIDE * device + button, down ? DOWN : UP);
    },
    rebind(line) {
      const [ptr, len] = rt.str_in(line);
      try {
        const rc = rt.call("app_rebind", app, ptr, len);
        if (rc === 0) return { ok: true };
        if (rc > 0) return { ok: false, conflicts: text(rt.call("app_text_len", app)).split(" ") };
        throw new Error(`game: rebind(${JSON.stringify(line)}) failed, see the console`);
      } finally {
        rt.free(ptr);
      }
    },
    resetBindings() { rt.call("app_bindings_reset", app); },
    access(line) {
      const [ptr, len] = rt.str_in(line);
      try {
        if (rt.call("app_access_set", app, ptr, len) !== 0) throw new Error(`game: access(${JSON.stringify(line)}) refused, see the console`);
      } finally {
        rt.free(ptr);
      }
    },
    accessText() { const n = rt.call("app_access_text", app); return n === 0 ? "" : text(n); },
    resetAccess() { rt.call("app_access_reset", app); },
    captionsLoad(track) {
      const [ptr, len] = rt.str_in(track);
      try {
        if (rt.call("app_captions_load", app, ptr, len) !== 0) throw new Error("game: captionsLoad: the track was refused, see the console");
      } finally {
        rt.free(ptr);
      }
    },
    say(speaker, line, ms = 3000) {
      const [ptr, len] = rt.str_in(speaker ? `${speaker}\t${line}` : line);
      try {
        rt.call("app_caption_say", app, ptr, len, ms);
      } finally {
        rt.free(ptr);
      }
    },
    captions: () => JSON.parse(text(rt.call("app_captions_state", app))),
    shake(trauma) { rt.call("app_shake", app, trauma); },
    shakeOffset: () => [rt.call("app_shake_offset", app, 0), rt.call("app_shake_offset", app, 1)],
    prompt(action, device = "keyboard") {
      const d = DEVICES[device];
      if (d === undefined) throw new Error(`game: prompt: device must be one of ${Object.keys(DEVICES).join(", ")}`);
      const [ptr, len] = rt.str_in(action);
      try {
        const n = rt.call("app_prompt", app, ptr, len, d);
        if (n < 0) throw new Error(`game: prompt: no action or slot ${JSON.stringify(action)}`);
        return n === 0 ? "" : text(n);
      } finally {
        rt.free(ptr);
      }
    },
    step(n = 1, draw = true) { frames(n, draw); return hook.hash(); },
    hash: () => BigInt.asUintN(64, rt.call("app_game_hash", app)).toString(),
    events: () => JSON.parse(text(rt.call("app_events", app))),
    configure(seed = 0, scene = "") {
      if (!/^\d+$/.test(String(seed))) throw new Error(`game: seed must be a non-negative integer, got ${JSON.stringify(seed)}`);
      const [ptr, len] = rt.str_in(scene);
      try {
        const rc = rt.call("app_configure", app, BigInt(seed), ptr, len);
        if (rc === -1) throw new Error("game: this game has no seeds or scenes (GameMode.reset returned False)");
        if (rc !== 0) throw new Error(`game: configure(${seed}, ${JSON.stringify(scene)}) failed (${rc}), see the console`);
      } finally {
        rt.free(ptr);
      }
    },
  };
  return hook;
}
