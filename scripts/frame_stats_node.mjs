// The scripted scene of docs/automation.md run through the real wasm64 app under node, frame by frame (`app_frame`, so every frame is
// timed), then the per-segment stats and the raw ring read back. No WebGPU under node: the draw, present and GPU rows do not run.
// usage: node --experimental-strip-types frame_stats_node.mjs app.wasm host.mjs wgpu-dir ma-dir job.json
// job.json: the game_run.mjs job (ticks, seed, scene, script) plus "audio_frames": frames mixed after each tick (default 800, 48 kHz / 60).
// Prints one JSON line: { frames, stats: [[avg, p50, p95, p99, max, count] x SEGMENTS], counters: [[last, avg, max] x COUNTERS],
//                         ring: [[SEGMENTS ns..., COUNTERS...] x frames], hash }
import { readFileSync } from "node:fs";

const [wasm, hostMjs, wgpuDir, maDir, jobFile] = process.argv.slice(2);
const { bootApp } = await import(new URL("./node_app.mjs", import.meta.url));
const { createGameHook } = await import(new URL("../shell/web/game_hook.mjs", import.meta.url));
const { keyCode } = await import(new URL("../shell/web/keys.ts", import.meta.url));
const SEGMENTS = 15, COUNTERS = 6, STAT_FIELDS = 6, CTR_FIELDS = 3, RING = 300;
const { rt } = await bootApp({ wasm, hostMjs, wgpuDir, maDir });
const job = { ticks: 600, seed: 0, scene: "", script: [], audio_frames: 800, ...JSON.parse(readFileSync(jobFile, "utf8")) };

const [ptr, len] = rt.str_in("#canvas");
const app = rt.call("app_init", ptr, len, 640, 480);
if (app === 0n) throw new Error("app_init returned 0");
if (rt.call("app_set_mode", app, 1) !== 0) throw new Error("app_set_mode failed");
const game = createGameHook({ rt, app, keyCode });
game.configure(job.seed, job.scene);

const pcm = rt.alloc(job.audio_frames * 2 * 4);
for (let tick = 0; tick < job.ticks; tick++) {
  for (const e of job.script) {
    if (e.tick !== tick) continue;
    if (e.hold) game.hold(e.hold);
    if (e.release) game.release(e.release);
    if (e.press) game.press(e.press);
  }
  game.step(1, true); // through app_frame: the frame is timed and its counters are set
  if (rt.call("app_audio_render", app, pcm, job.audio_frames) !== 0) throw new Error("app_audio_render failed");
}

const sbuf = rt.alloc((SEGMENTS * STAT_FIELDS + COUNTERS * CTR_FIELDS) * 8);
const frames = rt.call("app_frame_stats", app, sbuf);
const v = new BigUint64Array(rt.mem(), Number(sbuf), SEGMENTS * STAT_FIELDS + COUNTERS * CTR_FIELDS);
const stats = Array.from({ length: SEGMENTS }, (_, s) => Array.from(v.subarray(s * STAT_FIELDS, (s + 1) * STAT_FIELDS), Number));
const c0 = SEGMENTS * STAT_FIELDS;
const counters = Array.from({ length: COUNTERS }, (_, c) => Array.from(v.subarray(c0 + c * CTR_FIELDS, c0 + (c + 1) * CTR_FIELDS), Number));
const W = SEGMENTS + COUNTERS;
const rbuf = rt.alloc(RING * W * 8);
const n = rt.call("app_frame_ring", app, rbuf);
const r = new BigInt64Array(rt.mem(), Number(rbuf), n * W);
const ring = Array.from({ length: n }, (_, k) => Array.from(r.subarray(k * W, (k + 1) * W), Number));
console.log(JSON.stringify({ frames, stats, counters, ring, hash: BigInt.asUintN(64, rt.call("app_game_hash", app)).toString() }));
