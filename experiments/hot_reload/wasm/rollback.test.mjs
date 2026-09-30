// ===========================================================================
// W2: H1 (crash rollback) on the wasm host, with the Mojo core.
//
// v9_trap = v1 plus an out-of-bounds store in engine_update (a wasm trap).
// Protocol: v1 init(8), 30 frames, despawn 2 and 5, 10 frames; swap to
// v9_trap through LiveEngine (probation 60) with <strategy>; 30 frames; then
// swap to v2_code (auto) and run 70 frames.
//
// Predictions, written 2026-09-30 before LiveEngine existed:
//  control (plain hotSwap, no probation): the first engine_update after the
//    swap throws a RuntimeError out of the frame loop
//  memcopy-rw | snapshot | auto:
//    * the first frame rolls back; the old instance's frame counter is the
//      swap's frame_before (40) and it has 6 entities
//    * the 29 remaining frames run v1's code: final state equals the float32
//      oracle for v1 alone over 69 frames (red boxes)
//    * the following v2_code swap succeeds and commits after 60 frames
//
//   node experiments/hot_reload/wasm/rollback.test.mjs build/hot_mojo/manifest.json
// ===========================================================================
import { readFile } from "node:fs/promises";
import { createOracle } from "../../../tests/differential/lib/sparse_set_oracle.mjs";
import { LiveEngine, hotSwap } from "./hot_reload.mjs";

const manifest = JSON.parse(await readFile(process.argv[2] ?? "build/hot_mojo/manifest.json", "utf8"));
const CAPACITY = 8, PRE = 30, MID = 10, POST = 30;
const DT = Math.fround(1 / 60);
const load = async (v) => ({ ...v, bytes: await readFile(v.wasm) });
const v1 = await load(manifest.base);
const trap = await load(manifest.extra.find((v) => v.name === "v9_trap"));
const v2 = await load(manifest.variants.find((v) => v.name === "v2_code"));

function makeHost() {
  const h = { draws: [], live: null };
  h.imports = { host: { log: () => {}, draw_rect: (x, y, w, hh, rgba) => h.draws.push([x, y, w, hh, rgba >>> 0]) } };
  h.instantiate = async (mod) => (await WebAssembly.instantiate(mod, h.imports)).exports;
  return h;
}

function oracleV1(frames) {
  const ss = createOracle(CAPACITY);
  for (let i = 0; i < CAPACITY; i++) ss.add(i);
  let x = 0;
  const step = () => { x = Math.fround(x + Math.fround(60 * DT)); };
  for (let f = 0; f < PRE; f++) step();
  for (const e of [2, 5]) ss.remove(e);
  for (let f = PRE; f < frames; f++) step();
  return { count: ss.len(), frame: frames,
           draws: ss.dense().map((e) => [Math.fround(x + Math.fround(e * 24)), 0, 20, 20, 0xff0000ff]) };
}

async function boot(h) {
  const x = await h.instantiate(await WebAssembly.compile(v1.bytes));
  x.engine_init(CAPACITY);
  for (let f = 0; f < PRE; f++) x.engine_update(DT);
  for (const e of [2, 5]) x.engine_despawn(e);
  for (let f = 0; f < MID; f++) x.engine_update(DT);
  return x;
}

let failures = 0;
const check = (name, ok, detail) => {
  if (!ok) failures++;
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}  ${JSON.stringify(detail)}`);
};

// control: no probation
{
  const h = makeHost();
  const x = await boot(h);
  const r = await hotSwap(x, trap.bytes, h.instantiate, { strategy: "auto", capacity: CAPACITY,
    fingerprints: { old: v1.mapFingerprint, new: trap.mapFingerprint } });
  let thrown = null;
  try { r.exports.engine_update(DT); } catch (err) { thrown = err; }
  check("control: without probation the trap escapes the frame loop",
        thrown instanceof WebAssembly.RuntimeError, { error: String(thrown), used: r.strategy });
}

for (const strategy of ["memcopy-rw", "snapshot", "auto"]) {
  const h = makeHost();
  const live = new LiveEngine(await boot(h), { probation: 60 });
  const frameBefore = live.x.engine_frame();
  const sw = await live.swap(trap.bytes, h.instantiate, { strategy, capacity: CAPACITY,
    fingerprints: { old: v1.mapFingerprint, new: trap.mapFingerprint } });
  const events = [];
  let rb = null;
  for (let f = 0; f < POST; f++) {
    h.draws.length = 0;
    const ev = live.step(DT);
    events.push(ev.event);
    if (ev.event === "rollback" && !rb) rb = { ...ev, frame: live.x.engine_frame(), count: live.x.engine_entity_count() };
  }
  check(`${strategy}: first frame rolls back to frame_before with 6 entities`,
        sw.swapped && events[0] === "rollback" && rb.frame === frameBefore && rb.count === 6,
        { used: sw.swapped?.strategy, frameBefore, rollback: rb && { frame: rb.frame, count: rb.count, ms: rb.rollbackMs, error: rb.error } });
  const want = oracleV1(PRE + MID + POST - 1);
  const got = { count: live.x.engine_entity_count(), frame: live.x.engine_frame(), draws: h.draws };
  check(`${strategy}: then v1's code runs on: state equals the v1 oracle at frame ${want.frame}`,
        JSON.stringify(got) === JSON.stringify(want), { got: { count: got.count, frame: got.frame, draw0: got.draws[0] },
                                                         want: { count: want.count, frame: want.frame, draw0: want.draws[0] } });
  const sw2 = await live.swap(v2.bytes, h.instantiate, { strategy: "auto", capacity: CAPACITY,
    fingerprints: { old: v1.mapFingerprint, new: v2.mapFingerprint } });
  const ev2 = [];
  for (let f = 0; f < 70; f++) ev2.push(live.step(DT).event);
  check(`${strategy}: the next good build swaps and commits`,
        sw2.swapped && ev2.indexOf("commit") === 59 && !ev2.includes("rollback"),
        { used: sw2.swapped?.strategy, commitAtFrame: ev2.indexOf("commit") + 1, color: h.draws.at(-1)?.[4] });
}

if (failures) {
  console.log(`FAIL  ${failures} check(s) contradict the predictions`);
  process.exit(1);
}
console.log("PASS  wasm rollback: all observations match predictions");
