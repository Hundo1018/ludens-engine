// The real app under node (#120): the shipped audio files go through app_load_audio, the music plays, a bus is muted, a jump
// plays a positioned cue, and the master loudness is read. Prints one JSON object; scripts/audio_app_check.py judges it.
// usage: node audio_app.mjs app.wasm host.mjs wgpu-dir ma-dir audio-dir
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

globalThis.document ??= { querySelector: () => ({ width: 640, height: 480, getContext: () => ({}) }) };
const [wasm, hostMjs, wgpuDir, maDir, audioDir] = process.argv.slice(2);
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

const out = {};
const newApp = () => {
  const [ptr, len] = rt.str_in("#canvas");
  const app = rt.call("app_init", ptr, len, 640, 480);
  if (app === 0n) throw new Error("app_init returned 0");
  if (rt.call("app_set_mode", app, 1) !== 0) throw new Error("app_set_mode failed");
  return app;
};
const put = (bytes) => { const p = rt.alloc(Math.max(1, bytes.length)); rt.put(p, bytes); return p; };
const send = (app, name, bytes) => {
  const n = new TextEncoder().encode(name);
  return rt.call("app_load_audio", app, put(n), BigInt(n.length), put(bytes), BigInt(bytes.length));
};
const music = (app, name) => { const n = new TextEncoder().encode(name); return rt.call("app_music", app, put(n), BigInt(n.length)); };
const buf = rt.alloc(4800 * 2 * 4);
const render = (app, frames) => {
  const parts = [];
  for (let done = 0; done < frames; done += 4800) {
    const n = Math.min(4800, frames - done);
    if (rt.call("app_audio_render", app, buf, n) !== 0) throw new Error("app_audio_render failed");
    parts.push(Float32Array.from(rt.f32(buf, n * 2)));
  }
  return parts;
};
const rms = (parts) => { let s = 0, n = 0; for (const p of parts) for (const v of p) { s += v * v; n++; } return Math.sqrt(s / n); };

// 1. the shipped files, in the order of audio/index.txt
const app = newApp();
const list = readFileSync(`${audioDir}/index.txt`, "utf8").split("\n").filter(Boolean);
out.files = list.length;
out.loadCodes = list.map((n) => send(app, n, readFileSync(`${audioDir}/${n}`)));
out.garbage = send(app, "bad.lsound", new Uint8Array(40).fill(7));
out.unknownType = send(app, "x.wav", new Uint8Array(4));
out.noTrack = music(app, "nope");
out.calmCode = music(app, "calm");
// 2. one second of music
out.rmsMusic = rms(render(app, 48000));
out.momentary = rt.call("app_loudness", app, 0);
out.integrated = rt.call("app_loudness", app, 1);
// 3. the music bus muted: silent
rt.call("app_set_bus", app, 1, -6, 1);
out.rmsMuted = rms(render(app, 24000));
out.busBad = rt.call("app_set_bus", app, 9, 0, 0);
// 4. a jump with the music muted: the cue is logged and heard
const KEY = 1, DOWN = 1, UP = 0;
for (let f = 0; f < 5; f++) rt.call("app_frame", app, 1 / 60);
render(app, 12000);
rt.call("app_input", app, KEY, 32, DOWN, 0, 0, 0);
rt.call("app_frame", app, 1 / 60);
rt.call("app_input", app, KEY, 32, UP, 0, 0, 0);
const n = rt.call("app_events", app);
out.events = new TextDecoder().decode(new Uint8Array(rt.mem(), Number(rt.call("app_text_ptr", app)), n));
out.rmsJump = rms(render(app, 4800));
console.log(JSON.stringify(out));
