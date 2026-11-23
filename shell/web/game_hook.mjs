// The automation hook of the game: `window.game` in the page, the same object under node (scripts/game_run.mjs).
// Documented in docs/automation.md. It only calls the module's generic app_* exports; it knows no game.
//
//   state()          the game's state as an object (the JSON of GameMode.state)
//   press(key)       a tap: down and up inside one frame (the game sees the press edge, not a held key)
//   hold(key)        key down until release(key)
//   release(key)     key up;  releaseAll() lets go of everything
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
