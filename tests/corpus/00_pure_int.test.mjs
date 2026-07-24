// Capability corpus level 00: pure integer arithmetic from hand-written IR.
// Proves the retarget back-half is source-language independent.
//   node tests/corpus/00_pure_int.test.mjs [wasmPath]
import { readFile } from "node:fs/promises";

const wasmPath = process.argv[2] ?? "build/wasm/00_pure_int.wasm";
const { instance } = await WebAssembly.instantiate(await readFile(wasmPath), {});
const { add, sum_to } = instance.exports;

const cases = [
  ["add(2,3)", add(2, 3), 5],
  ["add(-4,9)", add(-4, 9), 5],
  ["sum_to(0)", sum_to(0), 0],
  ["sum_to(10)", sum_to(10), 45],
  ["sum_to(100)", sum_to(100), 4950],
];
let ok = true;
for (const [name, got, want] of cases) {
  const pass = got === want;
  ok &&= pass;
  console.log(`${pass ? "PASS" : "FAIL"}  ${name} = ${got} (want ${want})`);
}
if (!ok) process.exit(1);
console.log("PASS  corpus/00 pure-int (hand-written LLVM IR -> wasm)");
