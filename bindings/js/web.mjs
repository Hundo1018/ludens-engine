// ===========================================================================
// Browser driver: the SAME engine core + host as run-node.mjs, but with a real
// animation loop and an on-screen renderer.
//
// draw_rect currently paints to a 2D canvas so the demo runs in any browser
// with zero dependencies. In production this is where WebGPU lives: `onDraw`
// batches rects into a vertex buffer and issues one WebGPU draw call. The
// engine core is byte-for-byte identical either way -- rendering is the host's
// job (browser-first decision), the core just emits commands.
// ===========================================================================
import { makeHostImports } from "./host.mjs";

const canvas = document.getElementById("view");
const ctx = canvas.getContext("2d");
const logEl = document.getElementById("log");

const frame = []; // draw commands for the current frame
function onDraw(x, y, w, h, rgba) {
  frame.push({ x, y, w, h, rgba });
}
function paint() {
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  const cy = canvas.height / 2;
  for (const d of frame) {
    const r = (d.rgba >>> 24) & 0xff;
    const g = (d.rgba >>> 16) & 0xff;
    const b = (d.rgba >>> 8) & 0xff;
    const a = (d.rgba & 0xff) / 255;
    ctx.fillStyle = `rgba(${r},${g},${b},${a})`;
    // wrap x so the moving boxes stay on screen for the demo
    const x = ((d.x % (canvas.width + d.w)) + canvas.width + d.w) %
      (canvas.width + d.w) - d.w;
    ctx.fillRect(x, cy - d.h / 2, d.w, d.h);
  }
}

let instance;
const imports = makeHostImports({
  getMemory: () => instance.exports.memory,
  onDraw,
  log: (m) => {
    logEl.textContent = m;
    console.log(m);
  },
});

const bytes = await (await fetch("../../build/wasm/engine.wasm")).arrayBuffer();
({ instance } = await WebAssembly.instantiate(bytes, imports));
const engine = instance.exports;

engine.engine_init(6);

let last = performance.now();
function loop(t) {
  const dt = Math.min((t - last) / 1000, 1 / 30);
  last = t;
  frame.length = 0;
  engine.engine_update(dt); // core emits draw commands via host.draw_rect
  paint(); // host renders them (WebGPU in production)
  requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
