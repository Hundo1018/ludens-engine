// ===========================================================================
// Hot-reload latency benchmark (raw samples; run.py computes the summary).
//
//  swap:     v1 -> v2_code, per strategy, phases compile/instantiate/transfer/total
//  scaling:  transfer cost when the old instance's memory has grown to N MiB
//
// Every rep swaps in DIFFERENT bytes (a unique trailing custom section), so a
// V8 compiled-module cache keyed on wire bytes cannot make compile look free.
//
//   node experiments/hot_reload/wasm/bench.mjs [manifest.json] [out.json] [reps]
// ===========================================================================
import { readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import { hotSwap, snapshotTransfer, transplantMemory, dataSegments } from "./hot_reload.mjs";

const manifestPath = process.argv[2] ?? "build/hot/manifest.json";
const outPath = process.argv[3] ?? "build/hot/bench.json";
const REPS = Number(process.argv[4] ?? 200);
const SCALE_REPS = Math.max(10, Math.floor(REPS / 5));
const CAPACITY = 1000;
const DT = Math.fround(1 / 60);

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const v1 = { ...manifest.base, bytes: await readFile(manifest.base.wasm) };
const v2 = manifest.variants.find((v) => v.name === "v2_code");
v2.bytes = await readFile(v2.wasm);

// append custom section "bench" carrying `n` -> distinct bytes, same semantics
function uniquify(bytes, n) {
  const name = new TextEncoder().encode("bench");
  const payload = new Uint8Array(4);
  new DataView(payload.buffer).setUint32(0, n, true);
  const body = new Uint8Array([name.length, ...name, ...payload]);
  const out = new Uint8Array(bytes.length + 2 + body.length);
  out.set(bytes);
  out.set([0, body.length, ...body], bytes.length); // body.length < 128 -> 1-byte LEB
  return out;
}

function makeHost() {
  const h = { current: null };
  h.imports = { host: { log: () => {}, draw_rect: () => {} } };
  h.instantiate = async (mod) => (await WebAssembly.instantiate(mod, h.imports)).exports;
  return h;
}

async function liveV1(h) {
  const x = await h.instantiate(await WebAssembly.compile(v1.bytes));
  h.current = x;
  x.engine_init(CAPACITY);
  for (let f = 0; f < 60; f++) x.engine_update(DT);
  for (let e = 0; e < CAPACITY; e += 3) x.engine_despawn(e);
  return x;
}

const STRATS = ["restart", "memcopy-rw", "snapshot", "auto"];
const swap = Object.fromEntries(STRATS.map((s) => [s, { compile: [], instantiate: [], transfer: [], total: [] }]));
let n = 0;
for (let r = 0; r < REPS + 10; r++) { // first 10 = warm-up, discarded
  for (const s of STRATS) {
    const h = makeHost();
    const oldX = await liveV1(h);
    const res = await hotSwap(oldX, uniquify(v2.bytes, n++), h.instantiate, {
      strategy: s, capacity: CAPACITY,
      fingerprints: { old: v1.mapFingerprint, new: v2.mapFingerprint },
    });
    if (r >= 10) for (const k of Object.keys(res.ms)) swap[s][k].push(res.ms[k]);
  }
}

const ro = dataSegments(v2.bytes).filter((s) => s.name === ".rodata");
const scaling = [];
for (const mib of [1, 4, 16, 64]) {
  const row = { mib, memcopy: [], "memcopy-rw": [], snapshot: [] };
  for (let r = 0; r < SCALE_REPS; r++) {
    for (const s of ["memcopy", "memcopy-rw", "snapshot"]) {
      const h = makeHost();
      const oldX = await liveV1(h);
      const pages = mib * 16 - oldX.memory.buffer.byteLength / 65536;
      if (pages > 0) oldX.memory.grow(pages);
      const newX = await h.instantiate(await WebAssembly.compile(v2.bytes));
      const t0 = performance.now();
      if (s === "snapshot") snapshotTransfer(oldX, newX);
      else transplantMemory(oldX, newX, { skip: s === "memcopy-rw" ? ro : [] });
      row[s].push(performance.now() - t0);
    }
  }
  scaling.push(row);
}

const env = { node: process.version, cpu: os.cpus()[0]?.model ?? "?", cores: os.cpus().length,
              reps: REPS, scaleReps: SCALE_REPS, capacity: CAPACITY, wasmBytes: v2.bytes.length };
await writeFile(outPath, JSON.stringify({ env, swap, scaling }));
console.log(`wrote ${outPath} (${REPS} reps x ${STRATS.length} strategies, scaling ${SCALE_REPS} reps)`);
