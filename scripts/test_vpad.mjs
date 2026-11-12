// Virtual pad kit core (shell/web/vpad.ts) under node: fingers on sticks, buttons and the canvas become key, look and
// stick events. usage: node --experimental-strip-types scripts/test_vpad.mjs
import { VirtualPad, stickVector, vectorKeys } from "../shell/web/vpad.ts";

let passed = 0, failed = 0;
const ok = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const near = (a, b) => Math.abs(a - b) < 1e-9;
const K = { up: 87, down: 83, left: 65, right: 68 };
const JUMP = 32, PAUSE = 80;
const layout = (look = {}) => ({
  sticks: [{ id: "move", radius: 50, dead: 0.2, keys: K, at: { left: 30, bottom: 30 } }],
  buttons: [{ id: "jump", key: JUMP, label: "Jump", size: 80, at: { right: 30, bottom: 30 } },
            { id: "pause", key: PAUSE, label: "II", size: 40, at: { right: 10, top: 10 } },
            { id: "also-up", key: K.up, label: "^", size: 40, at: { left: 10, top: 10 } }],
  look,
});
const make = (look) => {
  const log = [];
  const sink = { key: (c, d) => log.push(`${d ? "+" : "-"}${c}`), look: (dx, dy) => log.push(`look ${dx} ${dy}`), lookEnd: () => log.push("end"),
                 stick: (id, x, y) => log.push(`${id} ${x.toFixed(2)} ${y.toFixed(2)}`) };
  return { log, pad: new VirtualPad(layout(look), sink), keys: () => log.filter((e) => /^[+-]\d/.test(e)).join(" ") };
};

// the vector
let v = stickVector(0, 0, 50, 0.2);
ok(v.x === 0 && v.y === 0, "a finger that has not moved: zero");
v = stickVector(8, 0, 50, 0.2);
ok(v.x === 0 && v.y === 0 && v.dx === 8, "inside the dead zone: zero, but the knob follows the finger");
v = stickVector(50, 0, 50, 0.2);
ok(near(v.x, 1) && v.y === 0, "at the radius: length 1");
v = stickVector(200, 0, 50, 0.2);
ok(near(v.x, 1) && v.dx === 50, "beyond the radius: still length 1, knob stops at the radius");
v = stickVector(30, 0, 50, 0.2);
ok(near(v.x, 0.5), `half way between the dead zone and the radius: 0.5 (${v.x})`);
v = stickVector(-300, 400, 50, 0.2);
ok(near(v.x, -0.6) && near(v.y, 0.8) && near(v.dx, -30) && near(v.dy, 40), "a diagonal beyond the radius keeps its direction");

// eight directions
const dir = (deg) => { const a = (deg * Math.PI) / 180; return vectorKeys(Math.cos(a), Math.sin(a), K).sort((a, b) => a - b).join(","); };
ok(vectorKeys(0, 0, K).length === 0, "no vector: no key");
ok(dir(0) === `${K.right}` && dir(180) === `${K.left}` && dir(-90) === `${K.up}` && dir(90) === `${K.down}`, "the four axes hold one key each");
ok(dir(-45) === `${K.right},${K.up}` && dir(135) === `${K.left},${K.down}`, "a diagonal holds two");
ok(dir(-20) === `${K.right}` && dir(-25) === `${K.right},${K.up}`, "the second key joins at 22.5 degrees off the axis");

// a stick: centre where the finger lands, keys follow the direction, lifting lets go
let t = make();
ok(t.pad.stickDown("move", 1, 100, 400) && t.log.length === 0, "a finger on the stick sends nothing until it moves");
t.pad.move(1, 104, 400);
ok(t.log.length === 0, "a small move sends nothing");
t.pad.move(1, 100, 350);
t.pad.move(1, 100, 340);
t.pad.move(1, 150, 350);
t.pad.up(1, 500);
ok(t.keys() === `+${K.up} +${K.right} -${K.up} -${K.right}`, `up, further up, up-right, lifted: ${t.keys()}`);
ok(t.log.filter((e) => e.startsWith("move")).join(" | ") === "move 0.00 -1.00 | move 0.71 -0.71 | move 0.00 0.00", `the vector is reported on change and returns to zero: ${t.log.filter((e) => e.startsWith("move")).join(" | ")}`);
ok(!t.pad.stick("move").active && t.pad.stick("move").dx === 0, "lifted: the stick is at rest");

// one finger per stick
t = make();
t.pad.stickDown("move", 1, 100, 400);
ok(t.pad.stickDown("move", 2, 120, 400) === false, "a second finger on the same stick is refused");
t.pad.move(2, 120, 300);
ok(t.log.length === 0, "and its moves do nothing");
ok(t.pad.stick("move").ox === 100, "the centre stays where the first finger landed");

// buttons, held with the stick
t = make();
t.pad.stickDown("move", 1, 100, 400);
t.pad.move(1, 100, 340);
t.pad.buttonDown("jump", 2);
t.pad.up(2, 100);
t.pad.buttonDown("pause", 3);
t.pad.up(3, 200);
t.pad.up(1, 300);
ok(t.keys() === `+${K.up} +${JUMP} -${JUMP} +${PAUSE} -${PAUSE} -${K.up}`, `stick held while Jump and Pause are tapped: ${t.keys()}`);
t = make();
t.pad.buttonDown("jump", 1);
t.pad.buttonDown("jump", 2);
t.pad.up(1, 10);
ok(t.keys() === `+${JUMP}` && t.pad.pressed("jump"), "two fingers on a button: still down after one lifts");
t.pad.up(2, 20);
ok(t.keys() === `+${JUMP} -${JUMP}` && !t.pad.pressed("jump"), "up after the last one lifts");

// a stick and a button that hold the same key do not release each other
t = make();
t.pad.buttonDown("also-up", 1);
t.pad.stickDown("move", 2, 100, 400);
t.pad.move(2, 100, 340);
t.pad.up(2, 50);
ok(t.keys() === `+${K.up}`, `the key stays down while the button still holds it: ${t.keys()}`);
t.pad.up(1, 60);
ok(t.keys() === `+${K.up} -${K.up}`, "and goes up with the button");

// look: a finger on no control
t = make();
ok(t.pad.lookDown(1, 700, 300, 0), "a finger on the canvas takes the camera");
t.pad.move(1, 715, 290);
t.pad.move(1, 725, 290);
ok(t.pad.lookDown(2, 600, 300, 0) === false, "a second finger on the canvas is ignored");
t.pad.up(1, 100);
ok(t.log.join(" ") === "look 15 -10 look 10 0 end", `a drag turns and ends once: ${t.log.join(" ")}`);
t = make();
t.pad.lookDown(1, 700, 300, 1000);
t.pad.up(1, 1100);
ok(t.log.join(" ") === "end", "without tapKey a tap presses nothing");
t = make({ tapKey: JUMP });
t.pad.lookDown(1, 700, 300, 1000);
t.pad.up(1, 1100);
ok(t.log.join(" ") === `end +${JUMP} -${JUMP}`, "with tapKey a short tap presses it");
t.log.length = 0;
t.pad.lookDown(2, 700, 300, 2000);
t.pad.up(2, 2600);
t.pad.lookDown(3, 700, 300, 3000);
t.pad.move(3, 740, 300);
t.pad.up(3, 3100);
t.pad.lookDown(4, 700, 300, 4000);
t.pad.up(4, 4050, true);
ok(!t.log.includes(`+${JUMP}`), "a long press, a drag and a cancelled touch are not taps");
const noLook = new VirtualPad({ sticks: [], buttons: [] }, { key() {}, look() {}, lookEnd() {} });
ok(noLook.lookDown(1, 0, 0, 0) === false, "a layout without `look` leaves canvas touches alone");

// a pointer belongs to one control
t = make();
t.pad.buttonDown("jump", 1);
ok(t.pad.stickDown("move", 1, 0, 0) === false && t.pad.lookDown(1, 0, 0, 0) === false, "a finger that is on a button cannot also take a stick or the camera");

// focus lost
t = make();
t.pad.stickDown("move", 1, 100, 400);
t.pad.move(1, 100, 460);
t.pad.buttonDown("jump", 2);
t.pad.lookDown(3, 700, 300, 0);
t.pad.move(3, 690, 300);
t.log.length = 0;
t.pad.release();
ok(t.log.join(" ") === `move 0.00 0.00 -${K.down} -${JUMP} end`, `everything is let go: ${t.log.join(" ")}`);
t.log.length = 0;
t.pad.move(1, 0, 0); t.pad.up(2, 10); t.pad.up(3, 10);
ok(t.log.length === 0, "events for forgotten fingers are ignored");
ok(t.pad.stickDown("move", 9, 50, 50), "and the stick takes a new finger");

console.log(`test_vpad: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
