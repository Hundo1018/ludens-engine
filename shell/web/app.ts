// Web shell: instantiate the one wasm64 module, drive it from requestAnimationFrame, feed DOM input in,
// and keep an AudioWorklet ring filled from app_audio_render.
import { instantiate } from "./host.mjs";
import { createImports as wgpuImports } from "./webgpu_host.mjs";
import { Runtime } from "./webgpu_runtime.mjs";
import * as miniaudio from "./miniaudio_host.mjs";
import * as net from "./net_host.mjs";
import { createGameHook } from "./game_hook.mjs";
import { createOsImports, opfsStorage } from "./os_host.mjs";
import { withViewRefs } from "./view_refs.mjs";
import { record } from "./record.js";
import { ACTION, BUTTONS, EV, keyCode } from "./keys.js";
import { PadInput, VPAD_DEVICE, padButtonKey, type Sink } from "./pad.js";
import type { PadLayout } from "./vpad.js";
import { mountVirtualPad } from "./vpad_view.js";
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
  audioStarts: number;
  exported?: number; // files the game asked to save and the page offered as downloads
  padLog: string[]; // what the virtual pad last sent (the newest 64 events), for the touch check
  error: string;
}
declare global {
  interface Window {
    shell: Stats & { app?: bigint; x?: AppExports; rt?: unknown };
  }
}
const stats: Window["shell"] = (window.shell = {
  started: false, frames: 0, contacts: 0, bodies: 0, played: 0, underruns: 0, rendered: 0, audioStarts: 0, padLog: [], error: "",
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
  // #147: a throw out of app_frame is written as a crash report (shell/web/crash_host.mjs) when the module has armed one.
  let osHost = undefined as { crash: { capture(e: unknown): Promise<Uint8Array | null> } } | undefined;
  // wgpu's createImports returns the flat env table; the shared host wants {namespace: table}.
  const rt = await instantiate(bytes, { libs: [() => ({ env: countImports(withViewRefs(wgpuImports(wrt))) }), miniaudio, net, (r) => (osHost = createOsImports(r, { storage: opfsStorage() }))] });
  wrt.attach(rt);
  const x = rt.exports as unknown as AppExports;
  const [sel, len] = rt.str_in("#" + canvas.id);
  const app = x.app_init(sel, len, canvas.width, canvas.height);
  if (app === 0n) throw new Error("app_init failed");
  // #116: the HUD's SDF font (assets/fonts, copied to ./font.lfont by build_web.py), loaded only for the game: ?selftest and
  // ?demo pages draw no text and do not fetch it. A failed load is logged and the game runs without text.
  if (!location.search.includes("selftest") && !location.search.includes("demo")) {
    try {
      const res = await fetch("./font.lfont");
      if (!res.ok) throw new Error("font.lfont: HTTP " + res.status);
      const fontBytes = new Uint8Array(await res.arrayBuffer());
      const fontPtr = rt.alloc(fontBytes.length);
      rt.put(fontPtr, fontBytes);
      const fontOk = x.app_load_font(app, fontPtr, BigInt(fontBytes.length));
      rt.free(fontPtr);
      if (fontOk !== 0) throw new Error("app_load_font returned " + fontOk);
    } catch (e) {
      console.warn("HUD font not loaded, text is not drawn: " + String(e));
    }
  }
  // #120: the music loops and the track list (assets/audio, copied to ./audio/ with audio-LICENSE.txt by build_web.py), loaded for the
  // game only. audio/index.txt lists the files, the clips first and music.music last; the module decodes them. A failed load is logged
  // and the game runs without music.
  const toWasm = (b: Uint8Array) => { const p = rt.alloc(Math.max(1, b.length)); rt.put(p, b); return p; };
  const sendAudio = (name: string, data: Uint8Array) => {
    const n = new TextEncoder().encode(name), np = toWasm(n), dp = toWasm(data);
    const rc = x.app_load_audio(app, np, BigInt(n.length), dp, BigInt(data.length));
    rt.free(np); rt.free(dp);
    if (rc !== 0) throw new Error("app_load_audio(" + name + ") returned " + rc);
  };
  const playMusic = (name: string) => {
    const n = new TextEncoder().encode(name), np = toWasm(n);
    const rc = x.app_music(app, np, BigInt(n.length));
    rt.free(np);
    return rc;
  };
  if (!location.search.includes("selftest") && !location.search.includes("demo")) {
    try {
      const list = (await (await fetch("./audio/index.txt")).text()).split("\n").filter(Boolean);
      for (const name of list) {
        const res = await fetch("./audio/" + name);
        if (!res.ok) throw new Error(name + ": HTTP " + res.status);
        sendAudio(name, new Uint8Array(await res.arrayBuffer()));
      }
      if (!params.has("nomusic")) playMusic("calm");
    } catch (e) {
      console.warn("music not loaded: " + String(e));
    }
  }
  // Volume per bus (0 master, 1 music, 2 sfx, 3 ambience, 4 ui, 5 voice; dB, mute: the accessibility menu's settings), the music
  // track (changes at the next bar line) and the master bus loudness in LUFS (0 momentary, 1 integrated).
  Object.defineProperty(stats, "setBus", { value: (bus: number, db: number, mute = false) => x.app_set_bus(app, bus, db, mute ? 1 : 0), enumerable: false, configurable: true });
  Object.defineProperty(stats, "music", { value: playMusic, enumerable: false, configurable: true });
  Object.defineProperty(stats, "loudness", { value: (which = 0) => x.app_loudness(app, which), enumerable: false, configurable: true });
  // Safe-area insets from the browser (CSS px -> canvas px), text scale and language from ?textscale=, ?lang=, ?pseudo and
  // ?safe=l,t,r,b (CSS px, for testing). setUi() changes them at run time.
  const ui = { textScale: Number(params.get("textscale") ?? 1), lang: params.get("lang") ?? navigator.language, pseudo: params.has("pseudo") };
  const applyUi = () => {
    const probe = document.createElement("div");
    probe.style.cssText = "position:fixed;left:0;top:0;visibility:hidden;padding:env(safe-area-inset-top,0px) env(safe-area-inset-right,0px) env(safe-area-inset-bottom,0px) env(safe-area-inset-left,0px)";
    document.body.append(probe);
    const cs = getComputedStyle(probe);
    let [l, t, r, b] = [cs.paddingLeft, cs.paddingTop, cs.paddingRight, cs.paddingBottom].map(parseFloat);
    probe.remove();
    const forced = params.get("safe");
    if (forced) [l, t, r, b] = forced.split(",").map(Number);
    const k = canvas.clientWidth > 0 ? canvas.width / canvas.clientWidth : 1;
    x.app_set_ui(app, ui.textScale, l * k, t * k, r * k, b * k, /^zh/i.test(ui.lang) ? 1 : 0, ui.pseudo ? 1 : 0);
  };
  applyUi();
  addEventListener("resize", applyUi);
  Object.defineProperty(stats, "setUi", {
    value: (o: Partial<typeof ui>) => { Object.assign(ui, o); applyUi(); }, enumerable: false, configurable: true,
  });
  // The demo game is the app; ?selftest keeps the physics demo that the parity gates and selftests measure.
  const gameMode = !location.search.includes("selftest") && !location.search.includes("demo");
  if (gameMode) x.app_set_mode(app, 1);
  // window.game (docs/automation.md): read the state, press keys, step with or without drawing. ?seed=N and ?scene=NAME start
  // the game over with that seed and scene; ?manual stops the animation loop, so frames come only from window.game.step.
  const game = createGameHook({ rt, app, keyCode });
  if (gameMode && (params.has("seed") || params.has("scene"))) game.configure(params.get("seed") ?? "0", params.get("scene") ?? "");
  (window as any).game = game;
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
  return { rt, x, app, crash: osHost?.crash };
}

const MANUAL = params.has("manual");

// The demo game's touch controls, as data for the virtual pad kit (vpad.ts): a move stick under the left thumb, Jump under the
// right, Pause and Restart out of the way at the top. A drag anywhere else on the canvas turns the camera. What each control
// does is not here: the stick is axes 0 / 1 of the on-screen pad (`vpad:a0`, `vpad:a1`) and the buttons are `vpad:b0`, `vpad:b9`,
// `vpad:b3`, which game/data/demo.actions binds to move, jump, pause and restart. The stick sends its raw vector (`dead: 0`);
// the map's dead zone shapes it.
const vpadButton = (n: number) => padButtonKey(VPAD_DEVICE, n);
const DEFAULT_PAD: PadLayout = {
  sticks: [{ id: "move", radius: 56, dead: 0, at: { left: 36, bottom: 36 }, axes: { x: 0, y: 1 } }],
  buttons: [
    { id: "jump", key: vpadButton(0), label: "Jump", size: 84, at: { right: 32, bottom: 40 } },
    { id: "pause", key: vpadButton(9), label: "II", size: 44, at: { right: 12, top: 12 } },
    { id: "restart", key: vpadButton(3), label: "R", size: 44, at: { right: 68, top: 12 } },
  ],
  look: {},
};

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
    axis: (device, axis, value) => send(EV.AXIS, axis, device, 0, value, 0), // key = axis index, action = device
    look: (dx, dy) => {
      if (!turning) { turning = true; send(EV.MOUSE_BUTTON, 0, ACTION.DOWN, 0, vx, vy); }
      vx += dx; vy += dy;
      send(EV.CURSOR_POS, 0, 0, 0, vx, vy);
    },
    lookEnd: () => { if (turning) { turning = false; send(EV.MOUSE_BUTTON, 0, ACTION.UP, 0, vx, vy); } },
  };
  const logged = (what: string) => { stats.padLog.push(what); if (stats.padLog.length > 64) stats.padLog.shift(); };
  const touch = mountVirtualPad(canvas, DEFAULT_PAD, {
    key: (code, down) => { logged(`${down ? "+" : "-"}${code}`); sink.key(code, down); },
    axis: (axis, value) => { logged(`a${axis}=${value}`); sink.axis!(VPAD_DEVICE, axis, value); },
    look: (dx, dy) => { logged("look"); sink.look(dx, dy); },
    lookEnd: () => { logged("end"); sink.lookEnd(); },
  }, location.search.includes("touch"));
  const pads = new Map<number, PadInput>();
  canvas.style.touchAction = "none"; // a drag on the canvas is input, not a page scroll
  const isTouch = (e: PointerEvent) => e.pointerType === "touch";
  // The pointer in canvas pixels: the page may show the canvas smaller than its 960 x 540 backing store.
  const cx = (e: PointerEvent) => (e.offsetX * canvas.width) / (canvas.clientWidth || canvas.width);
  const cy = (e: PointerEvent) => (e.offsetY * canvas.height) / (canvas.clientHeight || canvas.height);
  canvas.addEventListener("pointermove", (e) => {
    if (isTouch(e)) return; // the virtual pad has it
    vx = cx(e); vy = cy(e);
    send(EV.CURSOR_POS, 0, 0, mods(e), vx, vy);
  });
  canvas.addEventListener("pointerdown", (e) => {
    if (isTouch(e)) return;
    send(EV.MOUSE_BUTTON, BUTTONS[e.button] ?? 0, ACTION.DOWN, mods(e), cx(e), cy(e));
  });
  const up = (e: PointerEvent) => {
    if (isTouch(e)) return;
    send(EV.MOUSE_BUTTON, BUTTONS[e.button] ?? 0, ACTION.UP, mods(e), cx(e), cy(e));
  };
  canvas.addEventListener("pointerup", up);
  canvas.addEventListener("pointercancel", up);
  canvas.addEventListener("wheel", (e) => send(EV.SCROLL, 0, 0, mods(e), 0, -e.deltaY / 100), { passive: true });

  // Focus lost: releases happen in another window and never arrive, so let go of everything, here and in the app.
  const releaseAll = () => { touch.release(); for (const p of pads.values()) p.release(sink); pads.clear(); releaseHeld(); };
  addEventListener("blur", releaseAll);
  document.addEventListener("visibilitychange", () => { if (document.hidden) releaseAll(); });

  return (dtMs) => {
    const list = navigator.getGamepads ? navigator.getGamepads() : [];
    for (const [i, p] of pads) if (!list[i]) { p.release(sink); pads.delete(i); }
    for (const g of list) {
      if (!g || g.mapping !== "standard") continue;
      if (!pads.has(g.index)) pads.set(g.index, new PadInput(g.index));
      pads.get(g.index)!.poll(g.axes, g.buttons.map((b) => b.pressed), dtMs, sink);
    }
  };
}

// Audio out. With cross-origin isolation (COOP/COEP headers, as shell/web/serve.py sends) the rendered frames go to the
// worklet through a SharedArrayBuffer ring. A static host that cannot set headers (GitHub Pages) has no
// SharedArrayBuffer: there the same frames are posted to the worklet block by block, which keeps its own ring.
async function startAudio(rt: any, x: AppExports, app: bigint) {
  const shared = crossOriginIsolated;
  stats.audioStarts += 1;
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
  // Published before the wait: a context made on a gesture the browser does not count (a touch going down) stays
  // suspended, and a later gesture has to find it to resume it.
  Object.defineProperty(stats, "audio", { value: { ctx, node, shared }, enumerable: false, configurable: true });
  await ctx.resume();
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
  const { rt, x, app, crash } = await boot(canvas);
  const pollPads = attachInput(canvas, (k, key, a, m, px, py) => x.app_input(app, k, key, a, m, px, py), () => x.app_release_input(app));
  let fillAudio: (() => void) | null = null;
  // Two keys pressed before the first start resolves must not start two contexts: both would render the same mixer.
  let starting = false;
  const start = async () => {
    if (starting) {
      const a = (stats as any).audio;
      if (a && a.ctx.state !== "running") a.ctx.resume().catch(() => {});
      return;
    }
    starting = true;
    try { fillAudio = await startAudio(rt, x, app); } catch (e) { stats.error = String(e); }
  };
  // A touch counts as a user gesture when it is lifted, not when it lands, so the lift is listened for as well.
  for (const ev of ["pointerdown", "pointerup", "touchend", "keydown"]) addEventListener(ev, start);
  // A file the game asked to save (the tuning panel's Export): `<name>\n<text>`, offered as a download.
  const exportBuf = rt.alloc(1 << 20);
  const takeExport = () => {
    const n = x.app_take_export(app, exportBuf, BigInt(1 << 20));
    if (n === 0) return;
    if (n < 0) { stats.error = `export of ${-n} bytes does not fit its 1 MiB buffer`; return; }
    const text = new TextDecoder().decode(rt.bytes(exportBuf, n).slice());
    const nl = text.indexOf("\n");
    const a = document.createElement("a");
    const url = URL.createObjectURL(new Blob([text.slice(nl + 1)], { type: "text/plain" }));
    a.href = url;
    a.download = text.slice(0, nl);
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 10000); // not at once: some browsers read the blob after the click returns
    stats.exported = (stats.exported ?? 0) + 1;
  };
  let last = performance.now();
  const frame = (now: number) => {
    try {
      const dt = Math.min(Math.max((now - last) / 1000, 0), 0.1); last = now;
      calls.imports = 0; calls.webgpu = 0; calls.names = {};
      pollPads(dt * 1000);
      const r = x.app_frame(app, dt);
      if (r < 0) throw new Error("app_frame returned " + r);
      takeExport();
      if (r === 1) {
        stats.frames++;
        if (SELFTEST) stats.boundary = { exports: 1, imports: calls.imports, webgpu: calls.webgpu, names: { ...calls.names } };
      }
      if (SELFTEST) { stats.contacts = x.app_contacts(app); stats.bodies = x.app_body_count(app); }
      fillAudio?.();
      stats.started = true;
      requestAnimationFrame(frame);
    } catch (e) { stats.error = String(e); crash?.capture(e).catch(() => {}); }
  };
  if (MANUAL) stats.started = true; // frames come only from window.game.step
  else requestAnimationFrame(frame);
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

// #121: the particle frame (app/particle_frame.mojo, 480 x 270) against build/particles_native.rgba, same tolerance row.
async function particlePixelParity(x: AppExports, rt: any, app: bigint) {
  const W = 480, H = 270;
  x.app_particles_request(app);
  for (let i = 0; i < 1200 && x.app_particles_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const ptr = x.app_particles_ptr(app);
  if (ptr === 0n) throw new Error("particle frame never completed");
  const pitch = x.app_particles_pitch(app);
  const web = rt.bytes(ptr, pitch * H).slice() as Uint8Array;
  const native = new Uint8Array(await (await fetch("./particles_native.rgba")).arrayBuffer());
  if (native.length !== W * H * 4) throw new Error("particles_native.rgba has the wrong size " + native.length);
  let maxDelta = 0, over8 = 0, over32 = 0, lit = 0;
  for (let y = 0; y < H; y++) for (let xx = 0; xx < W; xx++) {
    const a = y * pitch + xx * 4, b = (y * W + xx) * 4;
    let d = 0;
    for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(web[a + c] - native[b + c]));
    if (d > maxDelta) maxDelta = d;
    if (d > 8) over8++;
    if (d > 32) over32++;
    if (native[b] > 200 && native[b + 1] > 120 && native[b + 2] < 120) lit++; // spark colours: the burst is in the picture
  }
  const browser = navigator.userAgent.includes("Firefox") ? "firefox" : "chrome";
  const table = await (await fetch("./pixel_tolerance.json")).json();
  const limits = table[browser];
  const stats = { maxDelta, fracOver8: over8 / (W * H), fracOver32: over32 / (W * H), sparkPixels: lit };
  const ok = lit > 60 && maxDelta <= limits.maxDelta && stats.fracOver8 <= limits.fracOver8 && stats.fracOver32 <= limits.fracOver32;
  return { browser, stats, limits, ok };
}

// #140: the tier 2 frame (app/tier2_frame.mojo: terrain, decals, trails; 480 x 270) against build/tier2_native.rgba, same
// tolerance row. More than 20 pixels of the cube's red decal (37 natively) and 40 of the blue tyre mark (354) must be in the native frame, so an
// empty or terrain-only frame cannot pass.
async function tier2PixelParity(x: AppExports, rt: any, app: bigint) {
  const W = 480, H = 270;
  x.app_tier2_request(app);
  for (let i = 0; i < 1200 && x.app_tier2_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const ptr = x.app_tier2_ptr(app);
  if (ptr === 0n) throw new Error("tier 2 frame never completed");
  const pitch = x.app_tier2_pitch(app);
  const web = rt.bytes(ptr, pitch * H).slice() as Uint8Array;
  const native = new Uint8Array(await (await fetch("./tier2_native.rgba")).arrayBuffer());
  if (native.length !== W * H * 4) throw new Error("tier2_native.rgba has the wrong size " + native.length);
  let maxDelta = 0, over8 = 0, over32 = 0, red = 0, blue = 0;
  for (let y = 0; y < H; y++) for (let xx = 0; xx < W; xx++) {
    const a = y * pitch + xx * 4, b = (y * W + xx) * 4;
    let d = 0;
    for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(web[a + c] - native[b + c]));
    if (d > maxDelta) maxDelta = d;
    if (d > 8) over8++;
    if (d > 32) over32++;
    if (native[b] > 180 && native[b + 1] < 60 && native[b + 2] < 60) red++;
    if (native[b + 2] > 200 && native[b] < 150) blue++;
  }
  const browser = navigator.userAgent.includes("Firefox") ? "firefox" : "chrome";
  const table = await (await fetch("./pixel_tolerance.json")).json();
  const limits = table[browser];
  const stats = { maxDelta, fracOver8: over8 / (W * H), fracOver32: over32 / (W * H), decalPixels: red, tyrePixels: blue };
  const ok = red > 20 && blue > 40 && maxDelta <= limits.maxDelta && stats.fracOver8 <= limits.fracOver8 && stats.fracOver32 <= limits.fracOver32;
  return { browser, stats, limits, ok };
}

// #139: the picture-effects frames (app/post_fx_frame.mojo, 480 x 270; 0 FXAA + bloom + grade, 1 MSAA 4x + bloom + grade)
// against build/post_fx_native.rgba and build/post_fx_msaa_native.rgba, same tolerance row.
async function postFxPixelParity(x: AppExports, rt: any, app: bigint, which: number) {
  const W = 480, H = 270;
  x.app_post_fx_request(app);
  for (let i = 0; i < 1200 && x.app_post_fx_ptr(app, which) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const ptr = x.app_post_fx_ptr(app, which);
  if (ptr === 0n) throw new Error("post fx frame " + which + " never completed");
  const pitch = x.app_post_fx_pitch(app);
  const web = rt.bytes(ptr, pitch * H).slice() as Uint8Array;
  const file = which === 0 ? "./post_fx_native.rgba" : "./post_fx_msaa_native.rgba";
  const native = new Uint8Array(await (await fetch(file)).arrayBuffer());
  if (native.length !== W * H * 4) throw new Error(file + " has the wrong size " + native.length);
  let maxDelta = 0, over8 = 0, over32 = 0, graded = 0;
  // pixels on an edge of the native frame (a luma step of more than 8 levels in the 3 x 3 around them), counted apart
  const luma = (o: number) => (native[o] + native[o + 1] + native[o + 2]) / 3;
  const edge = { pixels: 0, over8: 0, over32: 0, maxDelta: 0 }, flat = { over8: 0, over32: 0, maxDelta: 0 };
  for (let y = 0; y < H; y++) for (let xx = 0; xx < W; xx++) {
    const a = y * pitch + xx * 4, b = (y * W + xx) * 4;
    let d = 0;
    for (let c = 0; c < 4; c++) d = Math.max(d, Math.abs(web[a + c] - native[b + c]));
    if (d > maxDelta) maxDelta = d;
    if (d > 8) over8++;
    if (d > 32) over32++;
    if (native[b] > native[b + 2] + 40) graded++; // the warm grade: red well above blue; most of the picture
    let lo = 255, hi = 0;
    for (let j = -1; j <= 1; j++) for (let i = -1; i <= 1; i++) {
      const l = luma((Math.min(Math.max(y + j, 0), H - 1) * W + Math.min(Math.max(xx + i, 0), W - 1)) * 4);
      lo = Math.min(lo, l); hi = Math.max(hi, l);
    }
    const part = hi - lo > 8 ? edge : flat;
    if (part === edge) edge.pixels++;
    part.maxDelta = Math.max(part.maxDelta, d);
    if (d > 8) part.over8++;
    if (d > 32) part.over32++;
  }
  const browser = navigator.userAgent.includes("Firefox") ? "firefox" : "chrome";
  const table = await (await fetch("./pixel_tolerance.json")).json();
  const limits = table[browser];
  const stats = { maxDelta, fracOver8: over8 / (W * H), fracOver32: over32 / (W * H), gradedPixels: graded, edge, flat };
  // The MSAA frame (1): where the 4 samples of a pixel lie is up to the rasteriser, so a pixel on an edge can get a
  // different coverage (one step of the 4-sample pattern) than natively. Its pixels away from edges meet the row as for
  // any frame; its edge pixels meet the "msaaEdge" row of pixel_tolerance.json, measured and recorded there.
  const flatOk = flat.maxDelta <= limits.maxDelta && flat.over8 / (W * H) <= limits.fracOver8 && flat.over32 / (W * H) <= limits.fracOver32;
  const el = table.msaaEdge;
  const edgeOk = edge.maxDelta <= el.maxDelta && edge.over8 / edge.pixels <= el.fracOver8 && edge.over32 / edge.pixels <= el.fracOver32;
  const rowOk = maxDelta <= limits.maxDelta && stats.fracOver8 <= limits.fracOver8 && stats.fracOver32 <= limits.fracOver32;
  const ok = graded > 2000 && (which === 1 ? flatOk && edgeOk : rowOk);
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
        const pa = await particlePixelParity(x, rt, app);
        log.push(`particle pixel parity vs native (${pa.browser}): ${JSON.stringify(pa.stats)} limits ${JSON.stringify(pa.limits)}`);
        if (!pa.ok) return fail("particle pixels differ from the native render beyond the tolerance row");
        const t2 = await tier2PixelParity(x, rt, app);
        log.push(`tier 2 pixel parity vs native (${t2.browser}): ${JSON.stringify(t2.stats)} limits ${JSON.stringify(t2.limits)}`);
        if (!t2.ok) return fail("tier 2 pixels (terrain, decals, trails) differ from the native render beyond the tolerance row");
        for (const which of [0, 1]) {
          const pf = await postFxPixelParity(x, rt, app, which);
          log.push(`post fx frame ${which} pixel parity vs native (${pf.browser}): ${JSON.stringify(pf.stats)} limits ${JSON.stringify(pf.limits)}`);
          if (!pf.ok) return fail("post fx frame " + which + " differs from the native render beyond the tolerance row");
        }
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
