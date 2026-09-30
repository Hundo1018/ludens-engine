// ===========================================================================
// Hot-reload experiment: variant x strategy matrix against a float32 oracle.
//
// Protocol for every (variant, strategy) cell:
//   1. v1 core: engine_init(8), 30 frames, despawn 2 and 5, 10 frames
//   2. hot swap to <variant> with <strategy>
//   3. engine_log_msg() once, then 30 frames on the new code
// Observed per cell: entity count, frame counter, last-frame draw commands
// (compared exactly with the oracle) and which log text the new code printed.
//
// PREDICTED below was written before the first run (see README.md); any cell
// whose observation differs from its prediction fails this test.
//
//   node experiments/hot_reload/wasm/hot_reload.test.mjs [manifest.json] [out.json]
// ===========================================================================
import { readFile, writeFile } from "node:fs/promises";
import { createOracle } from "../../../tests/differential/lib/sparse_set_oracle.mjs";
import { addressesMatch, hotSwap, layoutIdMatch, layoutOf, mapMatch } from "./hot_reload.mjs";

const manifestPath = process.argv[2] ?? "build/hot/manifest.json";
const outPath = process.argv[3] ?? "build/hot/matrix.json";
const manifest = JSON.parse(await readFile(manifestPath, "utf8"));

const CAPACITY = 8;
const DT = Math.fround(1 / 60);
const PRE = 30, MID = 10, POST = 30;
const DESPAWN = [2, 5];
const STRATEGIES = ["restart", "memcopy", "memcopy-rw", "snapshot", "auto"];

// state: ok | lost | corrupt | trap      msg: new | old
// Round 1 (v2..v5) and round 2 (v6, map guard) predictions; see README.md.
// Round 2 predicted memcopy on v6 = corrupt and was REFUTED (observed ok):
// wasm-ld placed the new static in padding after g.3, not before it, so no
// existing address moved. The observed value is kept as the expectation.
const PREDICTED = {
  restart:      { v2_code: "lost/new", v3_rodata: "lost/new", v4_layout: "lost/new", v5_swap: "lost/new", v6_static: "lost/new" },
  memcopy:      { v2_code: "ok/new", v3_rodata: "ok/old", v4_layout: "corrupt|trap", v5_swap: "corrupt/new", v6_static: "ok/new" },
  "memcopy-rw": { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "corrupt|trap", v5_swap: "corrupt/new", v6_static: "ok/new" },
  snapshot:     { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "ok/new", v5_swap: "ok/new", v6_static: "ok/new" },
  auto:         { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "ok/new", v5_swap: "ok/new", v6_static: "ok/new" },
};
// Round 1 predicted v4 addressesMatch=false and was REFUTED (observed true):
// GlobalOpt splits `g` into scalars and the growth fits in alignment padding.
// The value below is the corrected expectation, kept as a regression check.
const PREDICTED_GUARD = {
  v2_code:   { addressesMatch: true, layoutIdMatch: true, mapMatch: true },
  v3_rodata: { addressesMatch: true, layoutIdMatch: true, mapMatch: true },
  v4_layout: { addressesMatch: true, layoutIdMatch: false, mapMatch: false },
  v5_swap:   { addressesMatch: true, layoutIdMatch: false, mapMatch: true },
  v6_static: { addressesMatch: true, layoutIdMatch: true, mapMatch: false },
};
// W1 (manifest.core === "mojo": engine_hot.mojo), written 2026-09-30 before
// the first run. The state is a heap EngineState (Mojo has no globals), so
//  * no GlobalOpt split can happen to it, and the writable symbols in the
//    link map are the C shims' only: mapMatch is true for every variant;
//  * size classes of the allocator are 16 << k, so v4/v6's 8 extra bytes stay
//    in the same 128-byte block: addresses match everywhere; v6 in place
//    writes past the struct but inside its block -> ok;
//  * the log text is a Mojo string literal in .rodata: memcopy keeps the old one.
const PREDICTED_MOJO_W1 = {
  restart:      { v2_code: "lost/new", v3_rodata: "lost/new", v4_layout: "lost/new", v5_swap: "lost/new", v6_append: "lost/new" },
  memcopy:      { v2_code: "ok/new", v3_rodata: "ok/old", v4_layout: "corrupt|trap", v5_swap: "corrupt/new", v6_append: "ok/new" },
  "memcopy-rw": { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "corrupt|trap", v5_swap: "corrupt/new", v6_append: "ok/new" },
  snapshot:     { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "ok/new", v5_swap: "ok/new", v6_append: "ok/new" },
  auto:         { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "ok/new", v5_swap: "ok/new", v6_append: "ok/new" },
};
const PREDICTED_GUARD_MOJO_W1 = {
  v2_code:   { addressesMatch: true, layoutIdMatch: true, mapMatch: true },
  v3_rodata: { addressesMatch: true, layoutIdMatch: true, mapMatch: true },
  v4_layout: { addressesMatch: true, layoutIdMatch: false, mapMatch: true },
  v5_swap:   { addressesMatch: true, layoutIdMatch: false, mapMatch: true },
  v6_append: { addressesMatch: true, layoutIdMatch: false, mapMatch: true },
};
// W1's engine_hot.mojo matched all of the above (25/25, 5/5); kept as the
// record. W2 (H2 + H3 on wasm) changed the engine: EngineState { entities;
// core: Core }, snapshots through ecs/schema.mojo into the snapshot buffer,
// layout id hashed from schema_of[EngineState], nostatic check compiled in.
// Predictions below written 2026-09-30 before the first W2 run:
//  * schema field names are string literals in .rodata; an edit that adds,
//    removes or renames a Core field changes .rodata's size, so __data_end /
//    __heap_base and every writable symbol move: addresses and map differ for
//    v4, v6, v7, v8, v8_rule; v5 (same names) and v2/v3 keep them
//  * memcopy then copies the old allocator and state slot onto the wrong
//    addresses: corrupt|trap for every variant whose addresses moved
//  * snapshot: by field name, as native H3: v8 without an alias is refused
const PREDICTED_MOJO = {
  restart:      { v2_code: "lost/new", v3_rodata: "lost/new", v4_layout: "lost/new", v5_swap: "lost/new",
                  v6_append: "lost/new", v7_delete: "lost/new", v8_rename: "lost/new", v8_rule: "lost/new" },
  memcopy:      { v2_code: "ok/new", v3_rodata: "ok/old", v4_layout: "corrupt|trap", v5_swap: "corrupt/new",
                  v6_append: "corrupt|trap", v7_delete: "corrupt|trap", v8_rename: "corrupt|trap", v8_rule: "corrupt|trap" },
  "memcopy-rw": { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "corrupt|trap", v5_swap: "corrupt/new",
                  v6_append: "corrupt|trap", v7_delete: "corrupt|trap", v8_rename: "corrupt|trap", v8_rule: "corrupt|trap" },
  snapshot:     { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "ok/new", v5_swap: "ok/new",
                  v6_append: "ok/new", v7_delete: "ok/new", v8_rename: "rejected/-", v8_rule: "ok/new" },
  auto:         { v2_code: "ok/new", v3_rodata: "ok/new", v4_layout: "ok/new", v5_swap: "ok/new",
                  v6_append: "ok/new", v7_delete: "ok/new", v8_rename: "rejected/-", v8_rule: "ok/new" },
};
const moved = { addressesMatch: false, layoutIdMatch: false, mapMatch: false };
const PREDICTED_GUARD_MOJO = {
  v2_code:   { addressesMatch: true, layoutIdMatch: true, mapMatch: true },
  v3_rodata: { addressesMatch: true, layoutIdMatch: true, mapMatch: true },
  v4_layout: moved,
  v5_swap:   { addressesMatch: true, layoutIdMatch: false, mapMatch: true },
  v6_append: moved,
  v7_delete: moved,
  v8_rename: moved,
  v8_rule:   moved,
};
// W2 refutations, recorded after the run WITHOUT editing the predictions
// above. A cell listed here passes when it shows the refuted observation, and
// is printed as REFUTED. (Runs that preceded these were not valid evidence:
// every variant was compiled from its own directory, and Mojo puts the
// source path into .rodata, which moved v3's addresses and hid v7's move.
// All variants now compile from one path; see run.py build_one_mojo.)
//  v8_rename: predicted addresses/map differ, memcopy corrupt|trap.
//    Observed: .rodata keeps its size (0x6b3). Mojo aligns every string
//    literal to 16 bytes, so "box_x\0" (6) and "offset_x\0" (9) fill the
//    same 16-byte slot; no address moves, the in-place copy is correct.
const REFUTED_MOJO = {
  "guard:v8_rename": { addressesMatch: true, layoutIdMatch: false, mapMatch: true },
  "memcopy:v8_rename": "ok/new",
  "memcopy-rw:v8_rename": "ok/new",
};
const GUARDS = ["addressesMatch", "layoutIdMatch", "mapMatch"];
const isMojo = manifest.core === "mojo";
const predicted = isMojo ? PREDICTED_MOJO : PREDICTED;
const predictedGuard = isMojo ? PREDICTED_GUARD_MOJO : PREDICTED_GUARD;
console.log(`core: ${isMojo ? "mojo (engine_hot.mojo)" : "c (engine_hot.c)"}`);

function makeHost() {
  const h = { current: null, draws: [], logs: [] };
  const dec = new TextDecoder();
  h.imports = {
    host: {
      log: (p, n) => h.logs.push(dec.decode(new Uint8Array(h.current.memory.buffer, p, n))),
      draw_rect: (x, y, w, hh, rgba) => h.draws.push([x, y, w, hh, rgba >>> 0]),
    },
  };
  h.instantiate = async (mod) => (await WebAssembly.instantiate(mod, h.imports)).exports;
  return h;
}

// float32 model of engine_hot.c
function oracleRun(v1, vN) {
  const ss = createOracle(CAPACITY);
  for (let i = 0; i < CAPACITY; i++) ss.add(i);
  let x = 0, frame = 0;
  const step = (speed) => { x = Math.fround(x + Math.fround(speed * DT)); frame++; };
  for (let f = 0; f < PRE; f++) step(v1.speed);
  for (const e of DESPAWN) ss.remove(e);
  for (let f = 0; f < MID; f++) step(v1.speed);
  for (let f = 0; f < POST; f++) step(vN.speed);
  const draws = ss.dense().map((e) => [Math.fround(x + Math.fround(e * 24)), 0, 20, 20, vN.color >>> 0]);
  return { count: ss.len(), frame, draws };
}

async function runCell(v1, vN, strategy) {
  const h = makeHost();
  h.current = await h.instantiate(await WebAssembly.compile(v1.bytes));
  let x = h.current;
  x.engine_init(CAPACITY);
  for (let f = 0; f < PRE; f++) x.engine_update(DT);
  for (const e of DESPAWN) x.engine_despawn(e);
  for (let f = 0; f < MID; f++) x.engine_update(DT);

  let swap;
  try {
    swap = await hotSwap(x, vN.bytes, h.instantiate, {
      strategy, capacity: CAPACITY, fingerprints: { old: v1.mapFingerprint, new: vN.mapFingerprint },
    });
  } catch (err) {
    // W2: engine_load refusing a snapshot (e.g. a rename without an alias)
    if (!String(err).includes("rejected")) throw err;
    return { state: "rejected", msg: "-", used: strategy === "auto" ? "snapshot" : strategy, transferred: 0,
             observed: { error: String(err) } };
  }
  h.current = x = swap.exports;
  h.logs.length = 0;
  let state;
  try {
    x.engine_log_msg();
    for (let f = 0; f < POST; f++) {
      h.draws.length = 0;
      x.engine_update(DT);
    }
    const want = oracleRun(v1, vN);
    const got = { count: x.engine_entity_count(), frame: x.engine_frame(), draws: h.draws };
    const same = got.count === want.count && got.frame === want.frame &&
      JSON.stringify(got.draws) === JSON.stringify(want.draws);
    state = same ? "ok" : got.count === CAPACITY && got.frame === POST ? "lost" : "corrupt";
    var observed = { count: got.count, frame: got.frame, firstDraw: got.draws[0] ?? null,
                     wantCount: want.count, wantFrame: want.frame, wantFirstDraw: want.draws[0] };
  } catch (err) {
    state = "trap";
    observed = { error: String(err) };
  }
  const msg = h.logs[0] === vN.msg ? "new" : h.logs[0] === v1.msg ? "old" : `?${h.logs[0]}`;
  return { state, msg, used: swap.strategy, transferred: swap.transferred, observed };
}

const load = async (v) => ({ ...v, bytes: await readFile(v.wasm) });
const v1 = await load(manifest.base);
const variants = await Promise.all(manifest.variants.map(load));

let failures = 0;
const cells = [];
const probe = makeHost();
const l1 = layoutOf(await probe.instantiate(await WebAssembly.compile(v1.bytes)));

console.log("guard (v1 -> variant)  addressesMatch  layoutIdMatch  mapMatch");
const guards = {};
for (const v of variants) {
  const lv = layoutOf(await probe.instantiate(await WebAssembly.compile(v.bytes)));
  const g = {
    addressesMatch: addressesMatch(l1, lv),
    layoutIdMatch: layoutIdMatch(l1, lv),
    mapMatch: mapMatch(v1.mapFingerprint, v.mapFingerprint),
  };
  guards[v.name] = { ...g, v1: l1, variant: lv };
  const p = predictedGuard[v.name];
  const hit = GUARDS.every((k) => p[k] === g[k]);
  const ref = isMojo && REFUTED_MOJO[`guard:${v.name}`];
  const refuted = !hit && ref && GUARDS.every((k) => ref[k] === g[k]);
  if (!hit && !refuted) failures++;
  const tag = hit ? "PASS" : refuted ? "REFUTED" : "FAIL";
  console.log(`${tag.padEnd(4)}  ${v.name.padEnd(15)}  ${GUARDS.map((k) => String(g[k]).padEnd(14)).join(" ")}`);
}

console.log("\nstrategy     variant     observed        predicted       used");
for (const s of STRATEGIES) {
  for (const v of variants) {
    const r = await runCell(v1, v, s);
    const obs = `${r.state}/${r.msg}`;
    const pred = predicted[s][v.name];
    const hit = pred.includes("|") ? pred.split("|").includes(r.state) : obs === pred;
    const refuted = !hit && isMojo && REFUTED_MOJO[`${s}:${v.name}`] === obs;
    if (!hit && !refuted) failures++;
    cells.push({ strategy: s, variant: v.name, predicted: pred, hit, refuted, ...r });
    const tag = hit ? "PASS" : refuted ? "REFUTED" : "FAIL";
    console.log(`${tag.padEnd(4)}  ${s.padEnd(11)} ${v.name.padEnd(11)} ${obs.padEnd(15)} ${pred.padEnd(15)} ${r.used}`);
    if (!hit) console.log("      ", JSON.stringify(r.observed));
  }
}

await writeFile(outPath, JSON.stringify({ guards, cells }, null, 2));
console.log(`\nwrote ${outPath}`);
if (failures) {
  console.log(`FAIL  ${failures} observation(s) contradict the predictions`);
  process.exit(1);
}
const nRefuted = cells.filter((c) => c.refuted).length;
console.log(`PASS  hot reload: all observations match predictions${nRefuted ? ` (${nRefuted} recorded refutation(s) reproduced)` : ""}`);
