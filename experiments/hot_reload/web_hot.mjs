// ===========================================================================
// Browser side of the hot-reload dev loop.
//
// Runs the engine core like bindings/js/web.mjs, and listens on
// /__hot/events (dev_server.py). Each successful rebuild is swapped in between
// two frames with hotSwap(..., "auto"): memory transplant when every layout
// guard passes, snapshot otherwise. A failed build leaves the running module
// untouched. Progress is exposed on window.__hot for the e2e test.
// ===========================================================================
import { makeHostImports } from "../../bindings/js/host.mjs";
import { hotSwap } from "./hot_reload.mjs";

const CAPACITY = 12;
const canvas = document.getElementById("view");
const ctx = canvas.getContext("2d");
const statusEl = document.getElementById("status");
const reloadsEl = document.getElementById("reloads");

const hot = (window.__hot = { version: 0, frame: 0, count: 0, color: null, reloads: [], errors: [], logs: [] });
const frame = [];
let x = null; // live engine exports
let fingerprint = null;

const imports = makeHostImports({
  getMemory: () => x.memory,
  onDraw: (px, py, w, h, rgba) => frame.push({ x: px, w, h, rgba }),
  log: (m) => hot.logs.push(m),
});
const instantiate = async (mod) => (await WebAssembly.instantiate(mod, imports)).exports;

function paint() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const cy = canvas.height / 2;
  for (const d of frame) {
    const r = (d.rgba >>> 24) & 0xff, g = (d.rgba >>> 16) & 0xff, b = (d.rgba >>> 8) & 0xff;
    ctx.fillStyle = `rgba(${r},${g},${b},${(d.rgba & 0xff) / 255})`;
    const span = canvas.width + d.w;
    ctx.fillRect((((d.x % span) + span) % span) - d.w, cy - d.h / 2, d.w, d.h);
  }
}

function render() {
  statusEl.textContent =
    `module v${hot.version} · frame ${hot.frame} · entities ${hot.count}` +
    (hot.errors.length ? ` · last build error: ${hot.errors.at(-1)}` : "");
  reloadsEl.textContent = hot.reloads
    .map((r) => `v${r.version}: ${r.strategy}, ${r.ms.toFixed(2)} ms swap, build ${r.buildMs} ms, ` +
                `frame ${r.frameBefore} -> ${r.frameAfter}`)
    .join("\n");
}

async function boot() {
  const build = await (await fetch("/__hot/latest")).json();
  const bytes = await (await fetch(build.wasm)).arrayBuffer();
  x = await instantiate(await WebAssembly.compile(bytes));
  x.engine_init(CAPACITY);
  x.engine_despawn(3); // non-trivial state: a restart would bring entity 3 back
  x.engine_despawn(7);
  fingerprint = build.mapFingerprint;
  hot.version = build.version;
}

async function onBuild(ev) {
  const build = JSON.parse(ev.data);
  if (!build.ok) {
    hot.errors.push(build.error);
    return;
  }
  if (build.version <= hot.version) return;
  const bytes = await (await fetch(build.wasm)).arrayBuffer();
  // Frames keep running on the old module while the new one compiles, so read
  // the counter after instantiation: from there to the transfer only
  // microtasks run, never a rAF callback.
  let frameBefore;
  const instantiateLast = async (mod) => {
    const e = await instantiate(mod);
    frameBefore = x.engine_frame();
    return e;
  };
  const res = await hotSwap(x, bytes, instantiateLast, {
    strategy: "auto", capacity: CAPACITY,
    fingerprints: { old: fingerprint, new: build.mapFingerprint },
  });
  x = res.exports; // no await between the transfer and this line: no frame runs on a half-swapped core
  fingerprint = build.mapFingerprint;
  hot.version = build.version;
  hot.reloads.push({ version: build.version, strategy: res.strategy, ms: res.ms.total,
                     buildMs: build.buildMs, frameBefore, frameAfter: x.engine_frame() });
}

let last = performance.now();
function loop(t) {
  const dt = Math.min((t - last) / 1000, 1 / 30);
  last = t;
  frame.length = 0;
  x.engine_update(dt);
  hot.frame = x.engine_frame();
  hot.count = x.engine_entity_count();
  hot.color = frame[0]?.rgba ?? null;
  paint();
  render();
  requestAnimationFrame(loop);
}

await boot();
new EventSource("/__hot/events").onmessage = (ev) => onBuild(ev).catch((e) => hot.errors.push(String(e)));
requestAnimationFrame(loop);
