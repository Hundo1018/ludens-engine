// Digest of the differential op sequence on a wasm SparseSet core, to compare
// with the native Mojo run (experiments/wasm_mojo/native_oracle.mojo).
//
//   node tests/differential/digest.mjs <wasm> <seed> <steps> [fixed_size=64]
//   -> digest=0x... len=<n>
//
// Same ops as sparse_set.test.mjs (mulberry32; key = floor(u * fixed); add if
// u < 0.6 else remove). After each step: FNV-1a over len and every dense key.
import { readFile } from "node:fs/promises";
import { mulberry32 } from "./lib/rng.mjs";

const [wasmPath, seedArg, stepsArg, fixedArg] = process.argv.slice(2);
const seed = Number(seedArg);
const steps = Number(stepsArg);
const FIXED = Number(fixedArg ?? 64);

const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const x = instance.exports;
const keyBytes = x.ss_key_bytes ? x.ss_key_bytes() : 4;
const dense = (h) => {
  const len = x.ss_len(h);
  const ptr = x.ss_dense_ptr(h);
  if (keyBytes === 8) return Array.from(new BigInt64Array(x.memory.buffer, ptr, len), Number);
  return Array.from(new Int32Array(x.memory.buffer, ptr, len));
};
const fnv = (h, v) => Math.imul((h ^ v) >>> 0, 16777619) >>> 0;

const handle = x.ss_create(FIXED);
const rnd = mulberry32(seed);
let h = 2166136261;
for (let step = 0; step < steps; step++) {
  const key = Math.floor(rnd() * FIXED);
  if (rnd() < 0.6) x.ss_add(handle, key);
  else x.ss_remove(handle, key);
  h = fnv(h, x.ss_len(handle));
  for (const k of dense(handle)) h = fnv(h, k);
}
console.log(`digest=0x${h.toString(16)} len=${x.ss_len(handle)}`);
