// ===========================================================================
// Dual-target differential test for the SparseSet core.
//
// Drives the SAME seeded op-sequence through:
//   * the wasm module  (LLVM IR -> llc -> wasm-ld, the retarget target), and
//   * the oracle        (JS reference; will be the native Mojo build).
// and asserts they stay observably identical: len, contains(k) for every key,
// and the packed dense array read ZERO-COPY out of wasm linear memory.
//
// This is the executable form of the "incremental breakpoint testing"
// methodology: any lowering divergence surfaces here, on a replayable seed,
// and you drop into the native oracle under lldb to see why.
//
//   node tests/differential/sparse_set.test.mjs [wasmPath] [seed] [steps]
// ===========================================================================
import { readFile } from "node:fs/promises";
import { mulberry32 } from "./lib/rng.mjs";
import { createOracle } from "./lib/sparse_set_oracle.mjs";

const wasmPath = process.argv[2] ?? "build/wasm/sparse_set.wasm";
const seed = Number(process.argv[3] ?? 0x1234abcd);
const steps = Number(process.argv[4] ?? 5000);
const FIXED = 64;

const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const x = instance.exports;
const mem = x.memory;

// zero-copy view of the wasm module's packed dense array
function wasmDense(handle) {
  const len = x.ss_len(handle);
  const ptr = x.ss_dense_ptr(handle);
  return Array.from(new Int32Array(mem.buffer, ptr, len));
}

const handle = x.ss_create(FIXED);
const oracle = createOracle(FIXED);
const rnd = mulberry32(seed);

let failures = 0;
const fail = (msg) => {
  if (++failures <= 10) console.error(`FAIL  ${msg}`);
};

for (let step = 0; step < steps; step++) {
  const key = Math.floor(rnd() * FIXED);
  const op = rnd();
  if (op < 0.6) {
    x.ss_add(handle, key);
    oracle.add(key);
  } else {
    x.ss_remove(handle, key);
    oracle.remove(key);
  }

  // invariant 1: length agrees
  if (x.ss_len(handle) !== oracle.len())
    fail(`step ${step}: len ${x.ss_len(handle)} != oracle ${oracle.len()}`);

  // invariant 2: membership agrees for EVERY possible key
  for (let k = 0; k < FIXED; k++) {
    const w = x.ss_contains(handle, k) === 1;
    const o = oracle.contains(k);
    if (w !== o) fail(`step ${step}: contains(${k}) wasm=${w} oracle=${o}`);
  }

  // invariant 3: the zero-copy dense array matches element-for-element
  const wd = wasmDense(handle);
  const od = oracle.dense();
  if (wd.length !== od.length || wd.some((v, i) => v !== od[i]))
    fail(`step ${step}: dense [${wd}] != oracle [${od}]`);

  if (failures) break;
}

if (failures) {
  console.error(`\n${failures} failure(s). Replay with:  ` +
    `node ${process.argv[1]} ${wasmPath} ${seed} ${steps}`);
  process.exit(1);
}
console.log(
  `PASS  differential  ${steps} steps, seed 0x${seed.toString(16)}, ` +
  `fixed_size ${FIXED}  (wasm == oracle on len, contains, zero-copy dense)`);
