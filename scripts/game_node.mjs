// Drives the real app under node (no WebGPU: the game steps before the GPU check) with keyboard events, then prints
// the game's numbers and whether the sound effects came out. usage: node game_node.mjs app.wasm host.mjs wgpu-dir ma-dir
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

globalThis.document ??= { querySelector: () => ({ width: 640, height: 480, getContext: () => ({}) }) };
const [wasm, hostMjs, wgpuDir, maDir] = process.argv.slice(2);
const load = (p) => import(pathToFileURL(p));
const { instantiate } = await load(hostMjs);
const { createImports } = await load(`${wgpuDir}/web/webgpu_host.mjs`);
const { Runtime } = await load(`${wgpuDir}/web/webgpu_runtime.mjs`);
const ma = await load(`${maDir}/web/miniaudio_host.mjs`);
const net = await import(new URL("../shell/web/net_host.mjs", import.meta.url));
const json = (p) => JSON.parse(readFileSync(p, "utf8"));
const wrt = new Runtime(json(`${wgpuDir}/web/webgpu_layout.json`), json(`${wgpuDir}/scripts/webgpu_enum_strings.json`));
const rt = await instantiate(readFileSync(wasm), { libs: [() => ({ env: createImports(wrt) }), ma, net] });
wrt.attach(rt);

const [ptr, len] = rt.str_in("#canvas");
const app = rt.call("app_init", ptr, len, 640, 480);
if (app === 0n) throw new Error("app_init returned 0");
if (rt.call("app_game_status", app) !== -1) throw new Error("a game before app_set_mode");
if (rt.call("app_set_mode", app, 1) !== 0) throw new Error("app_set_mode failed");

const KEY = 1, DOWN = 1, UP = 0;
const key = (k, a) => rt.call("app_input", app, KEY, k, a, 0, 0, 0);
key(68, DOWN); // D
const buf = rt.alloc(4800 * 2 * 4);
let rmsAfterJump = 0;
for (let f = 0; f < 240; f++) {
  if (f === 10) key(32, DOWN); // Space
  rt.call("app_frame", app, 1 / 60);
  if (f === 10) {
    key(32, UP);
    if (rt.call("app_audio_render", app, buf, 4800) !== 0) throw new Error("app_audio_render failed");
    const pcm = rt.f32(buf, 4800 * 2);
    rmsAfterJump = Math.sqrt(pcm.reduce((s, v) => s + v * v, 0) / pcm.length);
  }
}
const g = (n) => rt.call(n, app);
console.log(JSON.stringify({
  meshHash: BigInt.asUintN(64, rt.call("app_mesh_hash")).toString(),
  hash: BigInt.asUintN(64, g("app_game_hash")).toString(), score: Number(g("app_game_score")),
  collected: Number(g("app_game_collected")), status: Number(g("app_game_status")), rmsAfterJump,
}));
