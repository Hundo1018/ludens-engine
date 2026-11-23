// Runs the wasm app under node through the `window.game` hook (shell/web/game_hook.mjs), with no WebGPU and no drawing, and prints
// one JSON line per frame: {"tick": N, "hash": "...", "state": {...}}; tick 0 is the state before the first step, tick N the state
// after N steps. usage: node --experimental-strip-types game_run.mjs app.wasm host.mjs wgpu-dir ma-dir job.json
// job.json: { "ticks": 600, "seed": 0, "scene": "", "state": true, "events": false, "draw": false,
//             "script": [ { "tick": 10, "hold": "KeyD" }, { "tick": 40, "press": "Space" }, { "tick": 90, "release": "KeyD" } ] }
// "events": true adds the cues raised in each step as "events": [{frame, cue}]; "draw": true steps with step(1, true), which under node
// (no WebGPU) draws nothing either, so it checks that the draw flag does not change the simulation.
// A script entry applies before step number `tick` (counting from 0), so its effect is first visible in the line with tick + 1.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

globalThis.document ??= { querySelector: () => ({ width: 640, height: 480, getContext: () => ({}) }) };
const [wasm, hostMjs, wgpuDir, maDir, jobFile] = process.argv.slice(2);
const load = (p) => import(pathToFileURL(p));
const { instantiate } = await load(hostMjs);
const { createImports } = await load(`${wgpuDir}/web/webgpu_host.mjs`);
const { Runtime } = await load(`${wgpuDir}/web/webgpu_runtime.mjs`);
const ma = await load(`${maDir}/web/miniaudio_host.mjs`);
const net = await import(new URL("../shell/web/net_host.mjs", import.meta.url));
const { createGameHook } = await import(new URL("../shell/web/game_hook.mjs", import.meta.url));
const { keyCode } = await import(new URL("../shell/web/keys.ts", import.meta.url));
const json = (p) => JSON.parse(readFileSync(p, "utf8"));
const wrt = new Runtime(json(`${wgpuDir}/web/webgpu_layout.json`), json(`${wgpuDir}/scripts/webgpu_enum_strings.json`));
const rt = await instantiate(readFileSync(wasm), { libs: [() => ({ env: createImports(wrt) }), ma, net] });
wrt.attach(rt);

const job = { ticks: 600, seed: 0, scene: "", state: true, events: false, draw: false, script: [], ...json(jobFile) };
const [ptr, len] = rt.str_in("#canvas");
const app = rt.call("app_init", ptr, len, 640, 480);
if (app === 0n) throw new Error("app_init returned 0");
if (rt.call("app_set_mode", app, 1) !== 0) throw new Error("app_set_mode failed");
const game = createGameHook({ rt, app, keyCode });
game.configure(job.seed, job.scene);

const line = (tick) => JSON.stringify({
  tick, hash: game.hash(), ...(job.state ? { state: game.state() } : {}), ...(job.events && tick > 0 ? { events: game.events() } : {}),
});
const out = [line(0)];
for (let tick = 0; tick < job.ticks; tick++) {
  for (const e of job.script) {
    if (e.tick !== tick) continue;
    if (e.hold) game.hold(e.hold);
    if (e.release) game.release(e.release);
    if (e.press) game.press(e.press);
  }
  game.step(1, job.draw);
  out.push(line(tick + 1));
}
process.stdout.write(out.join("\n") + "\n");
