// Gamepad mapping (shell/web/pad.ts) under node: sticks and buttons become key and look events.
// usage: node --experimental-strip-types scripts/test_pad.mjs
import { HeldKeys, KEY, PadInput, padKeys, padLook } from "../shell/web/pad.ts";

let passed = 0, failed = 0;
const ok = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const sink = () => {
  const log = [];
  return { log, key: (c, d) => log.push(`${d ? "+" : "-"}${c}`), look: (dx, dy) => log.push(`look ${dx} ${dy}`), lookEnd: () => log.push("end") };
};
const btn = (...on) => { const b = Array(17).fill(false); for (const i of on) b[i] = true; return b; };
const set = (s) => [...s].sort((a, b) => a - b).join(",");

ok(set(padKeys([0, 0, 0, 0], btn())) === "", "a centred pad holds nothing");
ok(set(padKeys([0.1, -0.2, 0, 0], btn())) === "", "inside the dead zone holds nothing");
ok(set(padKeys([0.9, -0.9, 0, 0], btn())) === `${KEY.D},${KEY.W}`, "stick up-right: W and D");
ok(set(padKeys([-1, 1, 0, 0], btn())) === `${KEY.A},${KEY.S}`, "stick down-left: S and A");
ok(set(padKeys([0, 0, 0, 0], btn(12, 15))) === `${KEY.D},${KEY.W}`, "d-pad up + right: W and D");
ok(set(padKeys([0, 0, 0, 0], btn(0, 9, 3))) === `${KEY.SPACE},${KEY.P},${KEY.R}`, "A jumps, Start pauses, Y restarts");
ok(padLook([0, 0, 1, 0], 1000)[0] === 900 && padLook([0, 0, 1, 0], 1000)[1] === 0, "right stick full right for 1 s: 900 px");
ok(padLook([0, 0, 0.1, -0.2], 16).every((v) => v === 0), "right stick inside the dead zone: no turn");

// a pad over several frames: only changes are sent, look ends once
let s = sink();
const pad = new PadInput();
pad.poll([0, -1, 0, 0], btn(), 16, s);
pad.poll([0, -1, 0, 0], btn(), 16, s);
pad.poll([0, -1, 0.5, 0], btn(0), 20, s);
pad.poll([0, 0, 0, 0], btn(), 16, s);
pad.poll([0, 0, 0, 0], btn(), 16, s);
ok(s.log.join(" ") === `+${KEY.W} +${KEY.SPACE} look 9 0 -${KEY.W} -${KEY.SPACE} end`, `held keys are sent once, releases once, look ends once: ${s.log.join(" ")}`);
s = sink();
pad.poll([1, 0, 1, 0], btn(), 10, s);
pad.release(s);
ok(s.log.join(" ") === `+${KEY.D} look 9 0 -${KEY.D} end`, "a pad that disconnects lets go of everything");

const hk = new HeldKeys();
s = sink();
hk.set(new Set([1, 2]), s); hk.set(new Set([2, 3]), s);
ok(s.log.join(" ") === "+1 +2 -1 +3", "HeldKeys reports only the difference");

console.log(`test_pad: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
