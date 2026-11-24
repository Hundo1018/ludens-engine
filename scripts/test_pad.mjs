// Gamepad mapping (shell/web/pad.ts) under node: buttons become key codes, axes become AXIS events, the right stick turns the camera.
// usage: node --experimental-strip-types scripts/test_pad.mjs
import { HeldKeys, PAD_BUTTON_BASE, PadInput, VPAD_DEVICE, padButtonKey, padButtons, padLook } from "../shell/web/pad.ts";
import { ACTION, BUTTONS, EV, keyCode } from "../shell/web/keys.ts";

let passed = 0, failed = 0;
const ok = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const sink = () => {
  const log = [];
  return {
    log, key: (c, d) => log.push(`${d ? "+" : "-"}${c}`), axis: (dev, a, v) => log.push(`axis ${dev}.${a}=${v}`),
    look: (dx, dy) => log.push(`look ${dx} ${dy}`), lookEnd: () => log.push("end"),
  };
};
const btn = (...on) => { const b = Array(17).fill(false); for (const i of on) b[i] = true; return b; };
const set = (s) => [...s].sort((a, b) => a - b).join(",");

ok(padButtonKey(0, 0) === 400 && padButtonKey(1, 0) === 420 && padButtonKey(VPAD_DEVICE, 9) === 469 && PAD_BUTTON_BASE === 400, "button b of device d is key 400 + 20 d + b (game/action_map.mojo pad_button_key)");
ok(ACTION.DOWN === 1 && ACTION.UP === 0 && ACTION.REPEAT === 2 && BUTTONS.length === 3 && keyCode("KeyW") === 87 && keyCode("F2") === 291, "keys.ts still exports what app.ts imports (ACTION, BUTTONS, keyCode)");
ok(EV.AXIS === 5, "AXIS is event kind 5 (wgpu-mojo InputEventType.AXIS)");
ok(set(padButtons(0, btn())) === "", "no button, no key");
ok(set(padButtons(0, btn(0, 9, 3))) === "400,403,409", "A, Y and Start of gamepad 0 are keys 400, 403, 409");
ok(set(padButtons(1, btn(12))) === "432", "d-pad up of gamepad 1 is key 432");
ok(padLook([0, 0, 1, 0], 1000)[0] === 900 && padLook([0, 0, 1, 0], 1000)[1] === 0, "right stick full right for 1 s: 900 px");
ok(padLook([0, 0, 0.1, -0.2], 16).every((v) => v === 0), "right stick inside the dead zone: no turn");

// a pad over several frames: only changes are sent, look ends once; the stick is sent raw (the game's map owns the dead zone)
let s = sink();
const pad = new PadInput(0);
pad.poll([0, -1, 0, 0], btn(), 16, s);
pad.poll([0, -1, 0, 0], btn(), 16, s);
pad.poll([0.1, -1, 0.5, 0], btn(0), 20, s);
pad.poll([0, 0, 0, 0], btn(), 16, s);
pad.poll([0, 0, 0, 0], btn(), 16, s);
ok(
  s.log.join(" ") === "axis 0.1=-1 +400 axis 0.0=0.1 axis 0.2=0.5 look 9 0 -400 axis 0.0=0 axis 0.1=0 axis 0.2=0 end",
  `axes and keys are sent once per change, raw (0.1 is not zeroed here), look ends once: ${s.log.join(" ")}`,
);
s = sink();
pad.poll([1, 0, 1, 0], btn(), 10, s);
pad.release(s);
ok(s.log.join(" ") === "axis 0.0=1 axis 0.2=1 look 9 0 axis 0.0=0 axis 0.2=0 end", `a pad that disconnects zeroes its axes: ${s.log.join(" ")}`);
s = sink();
const second = new PadInput(1), fourth = new PadInput(3);
second.poll([0.5], btn(0), 16, s);
fourth.poll([0.5], btn(0), 16, s);
ok(s.log.join(" ") === "+420 axis 1.0=0.5", `the second gamepad is device 1; a fourth gamepad is ignored: ${s.log.join(" ")}`);

const hk = new HeldKeys();
s = sink();
hk.set(new Set([1, 2]), s); hk.set(new Set([2, 3]), s);
ok(s.log.join(" ") === "+1 +2 -1 +3", "HeldKeys reports only the difference");

console.log(`test_pad: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
