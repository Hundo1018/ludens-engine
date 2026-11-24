// Drives the real app under node (no WebGPU: the game steps before the GPU check) with keyboard events, then prints
// the game's numbers and whether the sound effects came out. usage: node game_node.mjs app.wasm host.mjs wgpu-dir ma-dir [stats-frames]
// With stats-frames (scripts/frame_budget.py), that many more frames run after the scripted ones and the JSON also
// carries app_frame_stats: per segment [p50, p95, max ns, frames it ran in] (app/frame_stats.mojo).

const [wasm, hostMjs, wgpuDir, maDir, statsFrames] = process.argv.slice(2);
const { bootApp } = await import(new URL("./node_app.mjs", import.meta.url));
const { rt } = await bootApp({ wasm, hostMjs, wgpuDir, maDir });

const [ptr, len] = rt.str_in("#canvas");
const app = rt.call("app_init", ptr, len, 640, 480);
if (app === 0n) throw new Error("app_init returned 0");
if (rt.call("app_game_hash", app) !== 0n) throw new Error("a game before app_set_mode");
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
const out = {
  meshHash: BigInt.asUintN(64, rt.call("app_mesh_hash")).toString(),
  hash: BigInt.asUintN(64, g("app_game_hash")).toString(), rmsAfterJump,
};
if (statsFrames) {
  for (let f = 0; f < Number(statsFrames); f++) rt.call("app_frame", app, 1 / 60);
  const SEGMENTS = 9, FIELDS = 4, p = rt.alloc(SEGMENTS * FIELDS * 8);
  out.statsFrames = rt.call("app_frame_stats", app, p);
  const v = new BigUint64Array(rt.mem(), Number(p), SEGMENTS * FIELDS);
  out.stats = Array.from({ length: SEGMENTS }, (_, s) => Array.from(v.subarray(s * FIELDS, s * FIELDS + FIELDS), Number));
}
console.log(JSON.stringify(out));
