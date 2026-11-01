// B1 acceptance: app_init + 1 frame under node must not trap (no WebGPU -> wgpu* imports are stubs).
// usage: node node_smoke.mjs app.wasm <ludens-wasm-rt host.mjs> <wgpu-mojo dir> <miniaudio-mojo dir>
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// No DOM and no WebGPU under node: a stand-in canvas so surface creation has something to bind.
globalThis.document ??= { querySelector: () => ({ width: 640, height: 480, getContext: () => ({}) }) };

const [wasm, hostMjs, wgpuDir, maDir] = process.argv.slice(2);
const load = (p) => import(pathToFileURL(p));
const { instantiate } = await load(hostMjs);
const { createImports } = await load(`${wgpuDir}/web/webgpu_host.mjs`);
const { Runtime } = await load(`${wgpuDir}/web/webgpu_runtime.mjs`);
const ma = await load(`${maDir}/web/miniaudio_host.mjs`);
const net = await import(new URL("../shell/web/net_host.mjs", import.meta.url)); // no ?ws: net_send answers -1, net_poll 0
const json = (p) => JSON.parse(readFileSync(p, "utf8"));
// wgpu's createImports takes its own handle-table Runtime and returns the flat `env` table.
const wrt = new Runtime(json(`${wgpuDir}/web/webgpu_layout.json`), json(`${wgpuDir}/scripts/webgpu_enum_strings.json`));
const rt = await instantiate(readFileSync(wasm), { libs: [() => ({ env: createImports(wrt) }), ma, net] });
wrt.attach(rt);

const [ptr, len] = rt.str_in("#canvas");
const app = rt.call("app_init", ptr, len, 640, 480);
console.log("app_init ->", app);
if (app === 0n) throw new Error("app_init returned 0");
console.log("app_frame ->", rt.call("app_frame", app, 1 / 60));
// Audio: 128 stereo frames must come back finite (silence is fine before any sound is started).
const buf = rt.alloc(128 * 2 * 4);
const rc = rt.call("app_audio_render", app, buf, 128);
const pcm = rt.f32(buf, 128 * 2);
if (rc !== 0 || !pcm.every(Number.isFinite)) throw new Error(`app_audio_render failed rc=${rc}`);
console.log("app_audio_render -> 0, 128 frames finite");
console.log("exports:", Object.keys(rt.exports).filter((k) => k.startsWith("app_")).join(","));
