// Web shell: instantiate the one wasm64 module, drive it from requestAnimationFrame, feed DOM input in,
// and keep an AudioWorklet ring filled from app_audio_render.
import { instantiate } from "./host.mjs";
import { createImports as wgpuImports } from "./webgpu_host.mjs";
import { Runtime } from "./webgpu_runtime.mjs";
import * as miniaudio from "./miniaudio_host.mjs";
import * as net from "./net_host.mjs";
import { ACTION, BUTTONS, EV, keyCode } from "./keys.js";
import type { AppExports } from "./exports";

const SAMPLE_RATE = 48000;
const CAPACITY = 8192; // ring size in frames
const TARGET_FRAMES = 6144; // how far ahead of playback to render
const BLOCK = 128;

interface Stats {
  started: boolean;
  frames: number;
  contacts: number;
  bodies: number;
  boundary?: { exports: number; imports: number; webgpu: number; names: Record<string, number> };
  played: number;
  underruns: number;
  rendered: number;
  error: string;
}
declare global {
  interface Window {
    shell: Stats & { app?: bigint; x?: AppExports; rt?: unknown };
  }
}
const stats: Window["shell"] = (window.shell = {
  started: false, frames: 0, contacts: 0, bodies: 0, played: 0, underruns: 0, rendered: 0, error: "",
});

// ?selftest only: count what crosses the JS boundary. `imports` are wasm -> JS calls (wgpu* entries into the
// translator), `webgpu` are the browser WebGPU API calls the translator makes in turn.
const SELFTEST = location.search.includes("selftest");
const calls = { imports: 0, webgpu: 0, names: {} as Record<string, number> };
function countImports(env: Record<string, (...a: unknown[]) => unknown>) {
  if (!SELFTEST) return env;
  for (const [k, fn] of Object.entries(env)) {
    env[k] = (...a: unknown[]) => { calls.imports++; calls.names[k] = (calls.names[k] ?? 0) + 1; return fn(...a); };
  }
  return env;
}
function countWebGPU() {
  if (!SELFTEST) return;
  for (const name of ["GPU", "GPUAdapter", "GPUDevice", "GPUQueue", "GPUCommandEncoder", "GPURenderPassEncoder", "GPUComputePassEncoder", "GPUCanvasContext", "GPUTexture", "GPUBuffer"]) {
    const proto = (globalThis as any)[name]?.prototype;
    if (!proto) continue;
    for (const k of Object.getOwnPropertyNames(proto)) {
      const d = Object.getOwnPropertyDescriptor(proto, k);
      if (k === "constructor" || typeof d?.value !== "function") continue;
      proto[k] = function (this: unknown, ...a: unknown[]) { calls.webgpu++; return d.value.apply(this, a); };
    }
  }
}

const json = async (u: string) => (await fetch(u)).json();

async function boot(canvas: HTMLCanvasElement) {
  countWebGPU();
  const [layout, enums, bytes] = await Promise.all([
    json("./webgpu_layout.json"), json("./webgpu_enum_strings.json"),
    fetch("./app.wasm").then((r) => r.arrayBuffer()),
  ]);
  const wrt = new Runtime(layout, enums);
  // wgpu's createImports returns the flat env table; the shared host wants {namespace: table}.
  const rt = await instantiate(bytes, { libs: [() => ({ env: countImports(wgpuImports(wrt)) }), miniaudio, net] });
  wrt.attach(rt);
  const x = rt.exports as unknown as AppExports;
  const [sel, len] = rt.str_in("#" + canvas.id);
  const app = x.app_init(sel, len, canvas.width, canvas.height);
  if (app === 0n) throw new Error("app_init failed");
  // Non-enumerable: bigint is not JSON-serialisable and the automated checks stringify window.shell.
  // Read one frame back through wgpu's FrameCapture (rendered into an app-owned target; see app/main.mojo).
  const capturePixels = async () => {
    x.app_request_capture(app);
    for (let i = 0; i < 600 && x.app_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
    const ptr = x.app_capture_ptr(app);
    if (ptr === 0n) throw new Error("frame capture never completed");
    const pitch = x.app_capture_pitch(app), h = canvas.height, w = canvas.width;
    const d = rt.bytes(ptr, pitch * h).slice();
    x.app_capture_release(app);
    const ref = [d[0], d[1], d[2]]; // top-left pixel: the clear colour
    let other = 0;
    for (let y = 0; y < h; y++) for (let xx = 0; xx < w; xx++) {
      const o = y * pitch + xx * 4;
      if (Math.abs(d[o] - ref[0]) + Math.abs(d[o + 1] - ref[1]) + Math.abs(d[o + 2] - ref[2]) > 40) other++;
    }
    return { width: w, height: h, pitch, format: x.app_format(app), clear: ref, other };
  };
  for (const [k, v] of Object.entries({ app, x, rt, capturePixels })) Object.defineProperty(stats, k, { value: v, enumerable: false });
  return { rt, x, app };
}

function attachInput(canvas: HTMLCanvasElement, send: (kind: number, key: number, action: number, mods: number, x: number, y: number) => void) {
  const mods = (e: KeyboardEvent | MouseEvent) => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0);
  addEventListener("keydown", (e) => { const k = keyCode(e.code); if (k >= 0) send(EV.KEY, k, e.repeat ? ACTION.REPEAT : ACTION.DOWN, mods(e), 0, 0); });
  addEventListener("keyup", (e) => { const k = keyCode(e.code); if (k >= 0) send(EV.KEY, k, ACTION.UP, mods(e), 0, 0); });
  canvas.addEventListener("pointermove", (e) => send(EV.CURSOR_POS, 0, 0, mods(e), e.offsetX, e.offsetY));
  canvas.addEventListener("pointerdown", (e) => send(EV.MOUSE_BUTTON, BUTTONS[e.button] ?? 0, ACTION.DOWN, mods(e), e.offsetX, e.offsetY));
  canvas.addEventListener("pointerup", (e) => send(EV.MOUSE_BUTTON, BUTTONS[e.button] ?? 0, ACTION.UP, mods(e), e.offsetX, e.offsetY));
  canvas.addEventListener("wheel", (e) => send(EV.SCROLL, 0, 0, mods(e), 0, -e.deltaY / 100), { passive: true });
}

async function startAudio(rt: any, x: AppExports, app: bigint) {
  if (!crossOriginIsolated) throw new Error("not cross-origin isolated: serve with shell/web/serve.py");
  const sab = new SharedArrayBuffer(16 + CAPACITY * 2 * 4);
  const ctl = new Int32Array(sab, 0, 4);
  const ring = new Float32Array(sab, 16, CAPACITY * 2);
  const ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
  await ctx.audioWorklet.addModule("./worklet.js");
  const node = new AudioWorkletNode(ctx, "ring-player", {
    outputChannelCount: [2], processorOptions: { sab, capacity: CAPACITY },
  });
  node.connect(ctx.destination);
  const scratch = rt.alloc(BLOCK * 2 * 4);
  const fill = () => {
    let w = Atomics.load(ctl, 0);
    const r = Atomics.load(ctl, 1);
    let buffered = (w - r + CAPACITY) % CAPACITY;
    while (buffered + BLOCK <= TARGET_FRAMES) {
      if (x.app_audio_render(app, scratch, BLOCK) !== 0) throw new Error("app_audio_render failed");
      const block = rt.f32(scratch, BLOCK * 2); // memory may have grown
      for (let i = 0; i < BLOCK; i++) {
        ring[2 * w] = block[2 * i]; ring[2 * w + 1] = block[2 * i + 1];
        w = (w + 1) % CAPACITY;
      }
      buffered += BLOCK; stats.rendered += BLOCK;
    }
    Atomics.store(ctl, 0, w);
    stats.played = Atomics.load(ctl, 3); stats.underruns = Atomics.load(ctl, 2);
  };
  node.port.onmessage = () => { try { fill(); } catch (e) { stats.error = String(e); } };
  await ctx.resume();
  return fill;
}

async function main() {
  const canvas = document.getElementById("canvas") as HTMLCanvasElement;
  const { rt, x, app } = await boot(canvas);
  attachInput(canvas, (k, key, a, m, px, py) => x.app_input(app, k, key, a, m, px, py));
  let fillAudio: (() => void) | null = null;
  const start = async () => {
    if (fillAudio) return;
    try { fillAudio = await startAudio(rt, x, app); } catch (e) { stats.error = String(e); }
  };
  addEventListener("pointerdown", start); addEventListener("keydown", start);
  let last = performance.now();
  const frame = (now: number) => {
    try {
      const dt = Math.min(Math.max((now - last) / 1000, 0), 0.1); last = now;
      calls.imports = 0; calls.webgpu = 0; calls.names = {};
      const r = x.app_frame(app, dt);
      if (r < 0) throw new Error("app_frame returned " + r);
      if (r === 1) {
        stats.frames++;
        if (SELFTEST) stats.boundary = { exports: 1, imports: calls.imports, webgpu: calls.webgpu, names: { ...calls.names } };
      }
      if (SELFTEST) { stats.contacts = x.app_contacts(app); stats.bodies = x.app_body_count(app); }
      fillAudio?.();
      stats.started = true;
      requestAnimationFrame(frame);
    } catch (e) { stats.error = String(e); }
  };
  requestAnimationFrame(frame);
  if (location.search.includes("selftest")) selftest(x, rt, app);
}

// ?selftest[&canvas-lost]: report PASS/FAIL in document.title and #log (the protocol of scripts/web_*.mjs).
// Headless Chrome destroys the GPUDevice after a canvas draw, so ?canvas-lost skips the pixel check there.
function selftest(x: AppExports, rt: any, app: bigint) {
  const log: string[] = [];
  const fail = (m: string) => { log.push("FAIL: " + m); finish(false); };
  const finish = (ok: boolean) => {
    document.getElementById("log")!.textContent = log.join("\n");
    document.title = ok ? "PASS" : "FAIL";
  };
  const timer = setInterval(async () => {
    try {
      if (stats.error) { clearInterval(timer); return fail("page error: " + stats.error); }
      if (stats.frames < 120 || stats.contacts === 0) return;
      clearInterval(timer);
      log.push(`frames ${stats.frames}, contacts ${stats.contacts}, bodies ${stats.bodies}`);
      const bd = stats.boundary!;
      log.push(`boundary per frame: ${bd.exports} export call (app_frame), ${bd.imports} wgpu* imports, ${bd.webgpu} browser WebGPU calls`);
      log.push(`imports: ${JSON.stringify(bd.names)}`);
      if (stats.bodies < 2) return fail("expected the floor and falling boxes");
      const p = rt.alloc(256 * 8);
      let rms = 0;
      for (let i = 0; i < 40; i++) { // the contact tone decays, so look at several blocks
        x.app_audio_render(app, p, 256);
        const b = rt.f32(p, 512) as Float32Array;
        rms = Math.max(rms, Math.sqrt(b.reduce((a, v) => a + v * v, 0) / b.length));
      }
      log.push(`audio rms ${rms.toFixed(4)}`);
      if (!(rms > 0.001)) return fail("no contact tone in the audio output");
      if (location.search.includes("canvas-lost")) log.push("pixel check skipped (canvas-lost)");
      else {
        const cap = await (window.shell as any).capturePixels();
        log.push(`capture ${JSON.stringify(cap)}`);
        if (cap.other < 2000) return fail("the frame holds only the clear colour");
      }
      finish(true);
    } catch (e) { clearInterval(timer); fail(String(e)); }
  }, 250);
}
main().catch((e) => { stats.error = String(e); });
