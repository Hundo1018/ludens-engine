// Crash reports on the web (ludens-engine #147): app/crash_probe.mojo compiled to wasm64 with DWARF line tables, stripped,
// and its source map (scripts/wasm_sourcemap.py). The module arms a crash context through os_crash_arm, traps on a load far
// outside linear memory, and shell/web/crash_host.mjs writes the report to the os_* storage without calling into the
// module. A second instance on the same storage (the next launch) reads it through OsCloudSave and sends it over a
// MemoryTransport; a third finds nothing. Without consent nothing is written. Writes build/crash_web.report for
// scripts/telemetry_read.py.
// usage: node tests/test_crash.mjs <wasm> <map> <host.mjs> <wgpu-mojo dir> <miniaudio-mojo dir> <crash line> <out report>
import { readFileSync, writeFileSync } from "node:fs";
const [wasm, mapPath, hostMjs, wgpuDir, maDir, crashLine, outPath] = process.argv.slice(2);
const { bootApp } = await import(new URL("../scripts/node_app.mjs", import.meta.url));
const { memoryStorage } = await import(new URL("../shell/web/os_host.mjs", import.meta.url));
const { CRASH_PATH, parseWasmStack } = await import(new URL("../shell/web/crash_host.mjs", import.meta.url));
let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const tick = async () => { for (let i = 0; i < 4; i++) await new Promise((r) => setTimeout(r, 0)); };
const sourceMap = readFileSync(mapPath, "utf8");
const UP_WAITING = 1, UP_NONE = 2, UP_SENT = 3;
const FAR = 1n << 40n;

const launch = (storage, map = sourceMap) => bootApp({ wasm, hostMjs, wgpuDir, maDir, storage, sourceMap: map });
async function upload(rt, granted) {
  const h = rt.call("c_new");
  let st = rt.call("c_upload_start", h);
  for (let i = 0; i < 50 && st === UP_WAITING; i++) { await tick(); st = rt.call("c_upload_step", h, granted); }
  const n = rt.call("c_sent_len", h);
  return { st, sent: n > 0 ? rt.bytes(rt.call("c_sent_ptr", h), n).slice() : null };
}

console.log("crash on the web: trap, save, send on the next launch");
const storage = memoryStorage();
{
  const { rt, os } = await launch(storage);
  const h = rt.call("c_new");
  const n = rt.call("c_grant", h, 1);
  check(n > 1000 && os.crash.status.armed === 1, `armed: a ${n}-byte context (10 log lines, a 1000-byte black box)`);
  let err = null;
  try { rt.call("c_crash", h, FAR); } catch (e) { err = e; }
  check(err instanceof WebAssembly.RuntimeError, `the load traps: ${err?.name}: ${err?.message}`);
  const raw = parseWasmStack(err?.stack);
  const report = await os.crash.capture(err);
  check(report !== null && storage.files.has(CRASH_PATH), `the report is written to ${CRASH_PATH} (${report?.length} bytes)`);
  check(raw.length >= 2, `${raw.length} wasm frames in the stack; innermost wasm-function[${raw[0]?.funcIndex}]:0x${raw[0]?.offset.toString(16)}`);
  const { loadSourceMap, lookup } = await import(new URL("../shell/web/crash_host.mjs", import.meta.url));
  const at = lookup(loadSourceMap(sourceMap), raw[0].offset);
  check(at?.file === "app/crash_probe.mojo" && at?.line === Number(crashLine),
    `the innermost frame maps to ${at?.file}:${at?.line}:${at?.column} (the CRASH-LINE marker is line ${crashLine})`);
  writeFileSync(outPath, report);
}
{
  const { rt } = await launch(storage);
  const { st, sent } = await upload(rt, 1);
  const saved = readFileSync(outPath);
  check(st === UP_SENT && sent !== null && Buffer.compare(Buffer.from(sent), saved) === 0, `next launch: UP_SENT, the ${sent?.length} bytes sent are the saved report`);
  check(storage.files.get(CRASH_PATH)?.length === 0, "the slot is cleared (an empty file)");
}
{
  const { rt } = await launch(storage);
  const { st } = await upload(rt, 1);
  check(st === UP_NONE, "the launch after that: UP_NONE");
}
console.log("crash without consent");
{
  const s2 = memoryStorage();
  const { rt, os } = await launch(s2);
  const h = rt.call("c_new");
  check(rt.call("c_grant", h, 0) === 0, "not opted in: the context is empty and the host is disarmed");
  let err = null;
  try { rt.call("c_crash", h, FAR); } catch (e) { err = e; }
  const report = await os.crash.capture(err);
  check(report === null && !s2.files.has(CRASH_PATH) && os.crash.status.unarmed === 1, "the trap writes nothing");
}
console.log("crash without a source map");
{
  const s3 = memoryStorage();
  const { rt, os } = await launch(s3, null);
  const h = rt.call("c_new");
  rt.call("c_grant", h, 1);
  let err = null;
  try { rt.call("c_crash", h, FAR); } catch (e) { err = e; }
  const report = await os.crash.capture(err);
  check(report !== null, `still written (${report?.length} bytes), frames unmapped; scripts/telemetry_read.py --map maps them later`);
  writeFileSync(outPath + ".unmapped", report);
}
console.log(`test_crash: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
