// ===========================================================================
// Node driver + smoke test for the browser-host demo, headless.
//
// Instantiates engine.wasm, supplies the `host` platform imports, runs a few
// fixed-dt frames and asserts the engine emitted the expected draw commands.
// This is the CI-runnable proof that JS <-> wasm interop works end to end
// (the browser version, web.mjs, is the same core with a real canvas).
//
//   node bindings/js/run-node.mjs [wasmPath] [frames]
// ===========================================================================
import { readFile } from "node:fs/promises";
import { makeHostImports } from "./host.mjs";

const wasmPath = process.argv[2] ?? "build/wasm/engine.wasm";
const frames = Number(process.argv[3] ?? 3);
const CAPACITY = 4;
const DT = 1 / 60;

let instance;
const draws = [];
const logs = [];
const imports = makeHostImports({
  getMemory: () => instance.exports.memory,
  onDraw: (x, y, w, h, rgba) => draws.push({ x, y, w, h, rgba }),
  log: (m) => logs.push(m),
});

({ instance } = await WebAssembly.instantiate(await readFile(wasmPath), imports));
const engine = instance.exports;

engine.engine_init(CAPACITY);
for (let f = 0; f < frames; f++) {
  draws.length = 0;
  engine.engine_update(DT);
}

// assertions
let ok = true;
const check = (name, cond) => {
  ok &&= cond;
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}`);
};
check(`init logged (${logs[0] ?? "-"})`, logs.some((m) => m.includes("engine_init")));
check(`entity_count == ${CAPACITY}`, engine.engine_entity_count() === CAPACITY);
check(`emitted ${CAPACITY} draw cmds/frame`, draws.length === CAPACITY);
check("draw color is red (0xff0000ff)", draws.every((d) => d.rgba === 0xff0000ff));
check("boxes spaced 24px apart", draws.length >= 2 && Math.abs((draws[1].x - draws[0].x) - 24) < 1e-3);

console.log("last frame draw commands:", JSON.stringify(draws));
if (!ok) process.exit(1);
console.log("PASS  browser-host interop: engine core <- JS host, draw commands flow");
