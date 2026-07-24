// ===========================================================================
// Layer-A test: the engine core (Mojo, today a C stand-in) and a separate C
// translation unit (bindings/c/physics.c) are linked by wasm-ld into ONE wasm
// module and share ONE linear memory. Verifies that C reads the core's packed
// dense array with zero copies, three ways, and all agree with a JS oracle.
//
//   node tests/layer_a.test.mjs [wasmPath]
// ===========================================================================
import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2] ?? "build/wasm/engine.wasm";
const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const x = instance.exports;

const FIXED = 64;
const h = x.ss_create(FIXED);
const added = [2, 1, 40, 7, 63, 0];
for (const k of added) x.ss_add(h, k);
x.ss_remove(h, 7);

const present = added.filter((k) => k !== 7);
const expect = present.reduce((a, b) => a + b, 0);

// path 1: C physics via the core's exported accessors (intra-module calls)
const viaAccessors = x.physics_sum_keys(h);
// path 2: C physics over the raw shared linear memory (dense pointer + len)
const viaRawMem = x.physics_sum_dense(x.ss_dense_ptr(h), x.ss_len(h));
// path 3: JS reads the exact same bytes zero-copy
const jsView = Array.from(
  new Int32Array(x.memory.buffer, x.ss_dense_ptr(h), x.ss_len(h)),
);
const viaJs = jsView.reduce((a, b) => a + b, 0);

let ok = true;
const check = (name, got) => {
  const pass = got === expect;
  ok &&= pass;
  console.log(`${pass ? "PASS" : "FAIL"}  ${name} = ${got} (want ${expect})`);
};
check("C  via exported accessors", viaAccessors);
check("C  via raw shared memory ", viaRawMem);
check("JS via zero-copy view    ", viaJs);
console.log(`dense (shared memory): [${jsView}]`);

if (!ok) process.exit(1);
console.log("PASS  layer-A: core + C physics, one module, one memory, zero copy");
