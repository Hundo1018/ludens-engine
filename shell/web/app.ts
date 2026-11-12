// Web shell: instantiate the one wasm64 module, drive it from requestAnimationFrame, feed DOM input in,
// and keep an AudioWorklet ring filled from app_audio_render.
import { instantiate } from "./host.mjs";
import { createImports as wgpuImports } from "./webgpu_host.mjs";
import { Runtime } from "./webgpu_runtime.mjs";
import * as miniaudio from "./miniaudio_host.mjs";
import * as net from "./net_host.mjs";
import { createOsImports, opfsStorage } from "./os_host.mjs";
import { record } from "./record.js";
import { ACTION, BUTTONS, EV, keyCode } from "./keys.js";
import { PadInput, TouchInput, type Sink } from "./pad.js";
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

// ?ws=<url> opens the net_* WebSocket; ?selftest=net:<port> opens ws://127.0.0.1:<port>.
const params = new URLSearchParams(location.search);
const wsUrl = params.get("ws") ?? (/^net.*:(\d+)$/.exec(params.get("selftest") ?? "") ? "ws://127.0.0.1:" + /:(\d+)$/.exec(params.get("selftest")!)![1] : "");

async function boot(canvas: HTMLCanvasElement) {
  countWebGPU();
  if (wsUrl) net.connect(wsUrl);
  const [layout, enums, bytes] = await Promise.all([
    json("./webgpu_layout.json"), json("./webgpu_enum_strings.json"),
    fetch("./app.wasm").then((r) => r.arrayBuffer()),
  ]);
  const wrt = new Runtime(layout, enums);
  // wgpu's createImports returns the flat env table; the shared host wants {namespace: table}.
  const rt = await instantiate(bytes, { libs: [() => ({ env: countImports(wgpuImports(wrt)) }), miniaudio, net, (r) => createOsImports(r, { storage: opfsStorage() })] });
  wrt.attach(rt);
  const x = rt.exports as unknown as AppExports;
  const [sel, len] = rt.str_in("#" + canvas.id);
  const app = x.app_init(sel, len, canvas.width, canvas.height);
  if (app === 0n) throw new Error("app_init failed");
  // The arena game is the app; ?selftest keeps the physics demo that the parity gates and selftests measure.
  if (!location.search.includes("selftest") && !location.search.includes("demo")) x.app_set_mode(app, 1);
  if (location.search.includes("offscreen") && !location.search.includes("selftest")) x.app_offscreen(app, 1); // headless Chrome: never draw to the canvas
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

// Keyboard, mouse, touch and gamepads, all as the GLFW-coded events app_input takes. Returns the per-frame gamepad poll.
function attachInput(canvas: HTMLCanvasElement, send: (kind: number, key: number, action: number, mods: number, x: number, y: number) => void,
                     releaseHeld: () => void): (dtMs: number) => void {
  const mods = (e: KeyboardEvent | MouseEvent) => (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0);
  // Space, the arrows and Tab scroll or move focus in a page; the game owns them while the page has focus.
  const GAME_CODES = new Set(["Space", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Tab"]);
  addEventListener("keydown", (e) => {
    const k = keyCode(e.code);
    if (k < 0) return;
    if (GAME_CODES.has(e.code)) e.preventDefault();
    send(EV.KEY, k, e.repeat ? ACTION.REPEAT : ACTION.DOWN, mods(e), 0, 0);
  });
  addEventListener("keyup", (e) => { const k = keyCode(e.code); if (k >= 0) send(EV.KEY, k, ACTION.UP, mods(e), 0, 0); });

  // Touch and gamepad camera turns are a drag of a virtual cursor with the left button held: what the game already reads.
  // The virtual cursor starts where the real pointer last was, so taking over from the mouse adds no jump.
  let vx = 0, vy = 0, turning = false;
  const sink: Sink = {
    key: (code, down) => send(EV.KEY, code, down ? ACTION.DOWN : ACTION.UP, 0, 0, 0),
    look: (dx, dy) => {
      if (!turning) { turning = true; send(EV.MOUSE_BUTTON, 0, ACTION.DOWN, 0, vx, vy); }
      vx += dx; vy += dy;
      send(EV.CURSOR_POS, 0, 0, 0, vx, vy);
    },
    lookEnd: () => { if (turning) { turning = false; send(EV.MOUSE_BUTTON, 0, ACTION.UP, 0, vx, vy); } },
  };
  const touch = new TouchInput();
  const pads = new Map<number, PadInput>();
  canvas.style.touchAction = "none"; // a drag on the canvas is input, not a page scroll
  const isTouch = (e: PointerEvent) => e.pointerType === "touch";
  canvas.addEventListener("pointermove", (e) => {
    if (isTouch(e)) return touch.move(e.pointerId, e.offsetX, e.offsetY, sink);
    vx = e.offsetX; vy = e.offsetY;
    send(EV.CURSOR_POS, 0, 0, mods(e), e.offsetX, e.offsetY);
  });
  canvas.addEventListener("pointerdown", (e) => {
    if (isTouch(e)) { canvas.setPointerCapture(e.pointerId); return touch.start(e.pointerId, e.offsetX, e.offsetY, canvas.clientWidth, e.timeStamp); }
    send(EV.MOUSE_BUTTON, BUTTONS[e.button] ?? 0, ACTION.DOWN, mods(e), e.offsetX, e.offsetY);
  });
  const up = (e: PointerEvent) => {
    if (isTouch(e)) return touch.end(e.pointerId, e.timeStamp, sink);
    send(EV.MOUSE_BUTTON, BUTTONS[e.button] ?? 0, ACTION.UP, mods(e), e.offsetX, e.offsetY);
  };
  canvas.addEventListener("pointerup", up);
  canvas.addEventListener("pointercancel", up);
  canvas.addEventListener("wheel", (e) => send(EV.SCROLL, 0, 0, mods(e), 0, -e.deltaY / 100), { passive: true });

  // Focus lost: releases happen in another window and never arrive, so let go of everything, here and in the app.
  const releaseAll = () => { touch.release(sink); for (const p of pads.values()) p.release(sink); pads.clear(); releaseHeld(); };
  addEventListener("blur", releaseAll);
  document.addEventListener("visibilitychange", () => { if (document.hidden) releaseAll(); });

  return (dtMs) => {
    const list = navigator.getGamepads ? navigator.getGamepads() : [];
    for (const [i, p] of pads) if (!list[i]) { p.release(sink); pads.delete(i); }
    for (const g of list) {
      if (!g || g.mapping !== "standard") continue;
      if (!pads.has(g.index)) pads.set(g.index, new PadInput());
      pads.get(g.index)!.poll(g.axes, g.buttons.map((b) => b.pressed), dtMs, sink);
    }
  };
}

// Audio out. With cross-origin isolation (COOP/COEP headers, as shell/web/serve.py sends) the rendered frames go to the
// worklet through a SharedArrayBuffer ring. A static host that cannot set headers (GitHub Pages) has no
// SharedArrayBuffer: there the same frames are posted to the worklet block by block, which keeps its own ring.
async function startAudio(rt: any, x: AppExports, app: bigint) {
  const shared = crossOriginIsolated;
  const ctx = new AudioContext({ sampleRate: SAMPLE_RATE });
  await ctx.audioWorklet.addModule("./worklet.js");
  const scratch = rt.alloc(BLOCK * 2 * 4);
  const render = () => {
    if (x.app_audio_render(app, scratch, BLOCK) !== 0) throw new Error("app_audio_render failed");
    stats.rendered += BLOCK;
    return rt.f32(scratch, BLOCK * 2); // memory may have grown
  };
  let node: AudioWorkletNode;
  let fill: () => void;
  if (shared) {
    const sab = new SharedArrayBuffer(16 + CAPACITY * 2 * 4);
    const ctl = new Int32Array(sab, 0, 4);
    const ring = new Float32Array(sab, 16, CAPACITY * 2);
    node = new AudioWorkletNode(ctx, "ring-player", {
      outputChannelCount: [2], processorOptions: { sab, capacity: CAPACITY },
    });
    fill = () => {
      let w = Atomics.load(ctl, 0);
      const r = Atomics.load(ctl, 1);
      let buffered = (w - r + CAPACITY) % CAPACITY;
      while (buffered + BLOCK <= TARGET_FRAMES) {
        const block = render();
        for (let i = 0; i < BLOCK; i++) {
          ring[2 * w] = block[2 * i]; ring[2 * w + 1] = block[2 * i + 1];
          w = (w + 1) % CAPACITY;
        }
        buffered += BLOCK;
      }
      Atomics.store(ctl, 0, w);
      stats.played = Atomics.load(ctl, 3); stats.underruns = Atomics.load(ctl, 2);
    };
    node.port.onmessage = () => { try { fill(); } catch (e) { stats.error = String(e); } };
  } else {
    node = new AudioWorkletNode(ctx, "ring-player", { outputChannelCount: [2], processorOptions: { capacity: CAPACITY } });
    // The worklet reports how many frames it has played. What it holds, plus what is still on its way to it, is
    // everything sent minus that; topping up from the worklet's own count of what it holds would send the blocks in
    // flight a second time, and the worklet drops what does not fit.
    let sent = 0;
    const topUp = (played: number) => {
      const blocks = Math.floor((TARGET_FRAMES - (sent - played)) / BLOCK);
      if (blocks <= 0) return;
      const out = new Float32Array(blocks * BLOCK * 2);
      for (let b = 0; b < blocks; b++) out.set(render(), b * BLOCK * 2);
      sent += blocks * BLOCK;
      node.port.postMessage(out, [out.buffer]);
    };
    node.port.onmessage = (e) => {
      try { stats.played = e.data.played; stats.underruns = e.data.underruns; topUp(e.data.played); } catch (err) { stats.error = String(err); }
    };
    fill = () => {};
    topUp(0);
  }
  node.connect(ctx.destination);
  await ctx.resume();
  Object.defineProperty(stats, "audio", { value: { ctx, node, shared }, enumerable: false, configurable: true });
  return fill;
}

// What the page needs from the browser, checked before anything is loaded so a visitor gets a sentence, not a blank canvas.
function unsupported(): string {
  if (!("gpu" in navigator)) return "This page needs WebGPU, which this browser does not offer.";
  // A module with one 64-bit memory: (module (memory i64 1)). Browsers without memory64 reject it.
  const memory64 = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 5, 3, 1, 4, 1]);
  if (!WebAssembly.validate(memory64)) return "This page needs 64-bit WebAssembly memory (memory64), which this browser does not offer.";
  return "";
}

async function main() {
  const canvas = document.getElementById("canvas") as HTMLCanvasElement;
  const why = unsupported();
  if (why) {
    stats.error = why;
    const note = document.getElementById("log");
    if (note) note.textContent = why + " Chrome 133 or later, or Firefox 134 or later, on a desktop.";
    return;
  }
  const { rt, x, app } = await boot(canvas);
  const pollPads = attachInput(canvas, (k, key, a, m, px, py) => x.app_input(app, k, key, a, m, px, py), () => x.app_release_input(app));
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
      pollPads(dt * 1000);
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

// Native/web pixel parity: the reference frame (app/reference.mojo) rendered here against the one wgpu-native
// rendered headless (build/pixels_native.rgba). Tolerances are per browser, see shell/web/pixel_tolerance.json.
async function pixelParity(x: AppExports, rt: any, app: bigint) {
  const W = 960, H = 540;
  x.app_reference_request(app, 240);
  for (let i = 0; i < 1200 && x.app_reference_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const ptr = x.app_reference_ptr(app);
  if (ptr === 0n) throw new Error("reference frame never completed");
  const pitch = x.app_reference_pitch(app);
  const web = rt.bytes(ptr, pitch * H).slice() as Uint8Array;
  const native = new Uint8Array(await (await fetch("./pixels_native.rgba")).arrayBuffer());
  if (native.length !== W * H * 4) throw new Error("pixels_native.rgba has the wrong size " + native.length);
  let maxDelta = 0, over8 = 0, over32 = 0;
  for (let y = 0; y < H; y++) for (let xx = 0; xx < W; xx++) {
    const a = y * pitch + xx * 4, b = (y * W + xx) * 4;
    let d = 0;
    for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(web[a + c] - native[b + c]));
    if (d > maxDelta) maxDelta = d;
    if (d > 8) over8++;
    if (d > 32) over32++;
  }
  const browser = navigator.userAgent.includes("Firefox") ? "firefox" : "chrome";
  const table = await (await fetch("./pixel_tolerance.json")).json();
  const limits = table[browser];
  const stats = { maxDelta, fracOver8: over8 / (W * H), fracOver32: over32 / (W * H) };
  const ok = maxDelta <= limits.maxDelta && stats.fracOver8 <= limits.fracOver8 && stats.fracOver32 <= limits.fracOver32;
  return { browser, stats, limits, ok };
}

// ?selftest[&canvas-lost]: report PASS/FAIL in document.title and #log (the protocol of scripts/web_*.mjs).
// Headless Chrome destroys the GPUDevice after a canvas draw, so ?canvas-lost skips the pixel check there.
function selftest(x: AppExports, rt: any, app: bigint) {
  const mode = new URLSearchParams(location.search).get("selftest") ?? "";
  if (mode.startsWith("net")) return selftestNet(x, rt, app);
  if (mode.startsWith("record")) return selftestRecord(x, rt, app);
  if (mode === "parity-offscreen") x.app_offscreen(app, 1); // Chrome: never draw to the canvas
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
      if (mode === "canvas-lost" || mode === "parity-offscreen") log.push("canvas pixel check skipped (" + mode + ")");
      else {
        const cap = await (window.shell as any).capturePixels();
        log.push(`capture ${JSON.stringify(cap)}`);
        if (cap.other < 2000) return fail("the frame holds only the clear colour");
      }
      if (mode.startsWith("parity")) {
        const pp = await pixelParity(x, rt, app);
        log.push(`pixel parity vs native (${pp.browser}): ${JSON.stringify(pp.stats)} limits ${JSON.stringify(pp.limits)}`);
        if (!pp.ok) return fail("pixels differ from the native render beyond the tolerance row");
      }
      finish(true);
    } catch (e) { clearInterval(timer); fail(String(e)); }
  }, 250);
}
// ?selftest=net:<port>: one packet out through net_send, back through net_poll into Mojo, compared byte for byte.
function selftestNet(x: AppExports, rt: any, app: bigint) {
  x.app_offscreen(app, 1); // no canvas draw: the point here is the socket, and headless Chrome loses the device
  const report = (ok: boolean, text: string) => { document.getElementById("log")!.textContent = text; document.title = ok ? "PASS" : "FAIL"; };
  const payload = new TextEncoder().encode("ludens-b5 echo " + Math.random().toString(36).slice(2) + " \u00e9\u0000\u00ff");
  let sent = false;
  const timer = setInterval(() => {
    try {
      if (stats.error) { clearInterval(timer); return report(false, "FAIL: " + stats.error); }
      if (!sent && stats.frames > 5 && net.status.opened) {
        const p = rt.alloc(payload.length);
        rt.put(p, payload);
        const r = x.app_net_send(app, p, BigInt(payload.length));
        rt.free(p);
        if (r !== 0) { clearInterval(timer); return report(false, "FAIL: net_send returned " + r); }
        sent = true;
      }
      if (sent && x.app_net_packets(app) > 0) {
        clearInterval(timer);
        const len = x.app_net_last_len(app);
        const got = (rt.bytes(x.app_net_last_ptr(app), len) as Uint8Array).slice();
        const same = len === payload.length && got.every((b, i) => b === payload[i]);
        report(same, `sent ${payload.length} bytes, Mojo received ${len} bytes via net_poll, ${same ? "identical" : "DIFFERENT"}\n` +
          `socket opened ${net.status.opened}, sent ${net.status.sent}, received ${net.status.received}\nselftest: ${same ? "PASS" : "FAIL"}`);
      }
    } catch (e) { clearInterval(timer); report(false, "FAIL: " + e); }
  }, 100);
}

// ?selftest=record: 5 s of canvas + audio into a WebM, uploaded to the dev server (PUT /upload/recorded.webm) for ffmpeg.
function selftestRecord(x: AppExports, rt: any, app: bigint) {
  const report = (ok: boolean, text: string) => { document.getElementById("log")!.textContent = text; document.title = ok ? "PASS" : "FAIL"; };
  const timer = setInterval(async () => {
    try {
      if (stats.error) { clearInterval(timer); return report(false, "FAIL: " + stats.error); }
      if (stats.frames < 30) return;
      clearInterval(timer);
      const canvas = document.getElementById("canvas") as HTMLCanvasElement;
      let audio: any;
      // A runner without a sound device can leave AudioContext.resume() pending forever: give it 5 s, then record video only.
      try {
        await Promise.race([startAudio(rt, x, app), new Promise((_, rej) => setTimeout(() => rej(new Error("audio start timed out")), 5000))]);
        audio = (stats as any).audio;
      } catch (e) { stats.error = ""; audio = undefined; }
      document.getElementById("log")!.textContent = `recording (audio ${!!audio}, frames ${stats.frames})`;
      const rec = await record(canvas, 5, audio);
      document.getElementById("log")!.textContent = "recorded, checking";
      const buf = new Uint8Array(await rec.blob.arrayBuffer());
      const ebml = buf[0] === 0x1a && buf[1] === 0x45 && buf[2] === 0xdf && buf[3] === 0xa3;
      const put = await fetch("./upload/recorded.webm", { method: "PUT", body: buf });
      const v = document.createElement("video");
      v.muted = true; v.src = URL.createObjectURL(rec.blob);
      await new Promise((res, rej) => { v.onloadedmetadata = () => res(null); v.onerror = () => rej(new Error("<video> cannot load the recording")); });
      const ok = ebml && buf.length > 10000 && put.ok && v.videoWidth === canvas.width && v.videoHeight === canvas.height;
      report(ok, `recorded ${rec.seconds.toFixed(2)} s, ${buf.length} bytes, ${rec.mime}, video ${rec.video}, audio ${rec.audio}\n` +
        `EBML header ${ebml}, uploaded ${put.status}, <video> ${v.videoWidth}x${v.videoHeight}\nselftest: ${ok ? "PASS" : "FAIL"}`);
    } catch (e) { clearInterval(timer); report(false, "FAIL: " + e); }
  }, 250);
}
main().catch((e) => { stats.error = String(e); });
