// The frame-time overlay (F3) and the frame counters in headless Chrome (SwiftShader WebGPU). usage:
//   node scripts/perf_overlay_shot.mjs <chrome> <url> <out-prefix> [timeout_s]
// Exits non-zero unless: F3 draws the overlay (pixels in its corner differ from the frame without it, and F3 again hides it);
// app_frame_stats reports 300 frames, draw calls and triangles of the demo scene, its 9 bodies, the texture bytes the renderer's
// sizes give for this canvas, and no GPU rows (the browser has no timestamp queries; they are "did not run", not 0).
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, prefix, timeoutS = '120'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'perf-shot-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=700,500', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('perf_overlay_shot: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?${url}`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map(); const problems = [];
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') {
    const text = m.params.args.map((a) => a.value ?? a.description).join(' ');
    if (/wgpu uncaptured error|app_frame:|unimplemented on web/.test(text)) problems.push('browser console: ' + text.split('\n')[0]);
  }
  if (m.method === 'Runtime.exceptionThrown') { console.log('exception:', m.params.exceptionDetails.exception?.description); problems.push('page exception'); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await send('Runtime.enable');

const GRAB = `(async () => {
  const s = window.shell, x = s.x, app = s.app;
  x.app_request_capture(app);
  for (let i = 0; i < 900 && x.app_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.app_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.app_capture_pitch(app), c = document.querySelector('canvas'), w = c.width, h = c.height;
  const d = s.rt.bytes(p, pitch * h).slice(); x.app_capture_release(app);
  let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
  return { w, h, pitch, b64: btoa(bin) };
})()`;
async function shot(name) {
  const r = await js(GRAB);
  if (!r) { problems.push(`${name}: capture never completed`); return null; }
  const bytes = Buffer.from(r.b64, 'base64');
  writeFileSync(`${prefix}_${name}.rgba`, bytes);
  return { bytes, ...r };
}
const key = async (type, code) => js(`window.dispatchEvent(new KeyboardEvent('${type}', { code: '${code}', bubbles: true }))`);
const region = (a, b, x0, y0, x1, y1) => { // pixels of the rectangle whose colour differs by more than 60 (sum of channels)
  let n = 0;
  for (let y = y0; y < y1; y++) for (let x = x0; x < x1; x++) {
    const o = y * a.pitch + x * 4;
    if (Math.abs(a.bytes[o] - b.bytes[o]) + Math.abs(a.bytes[o + 1] - b.bytes[o + 1]) + Math.abs(a.bytes[o + 2] - b.bytes[o + 2]) > 60) n++;
  }
  return n;
};

for (let i = 0; i < 200; i++) { if ((await js('window.shell && window.shell.frames')) > 10) break; await sleep(250); }
console.log('frames', await js('window.shell.frames'), 'error', await js('window.shell.error'));
// the app draws on capture requests only in this headless mode: each GRAB is a frame
for (let i = 0; i < 305; i++) await js(GRAB);
const closed = await shot('closed');
await key('keydown', 'F3'); await shot('held'); await key('keyup', 'F3'); await sleep(300);
const open = await shot('open');
const w = closed.w;
const shown = region(closed, open, 8, 8, Math.min(400, w), 200);
console.log('overlay corner: ' + shown + ' of ' + (192 * Math.min(392, w - 8)) + ' pixels differ from the frame without it');
if (shown < 3000) problems.push('F3 did not draw the overlay');
await key('keydown', 'F3'); await shot('held2'); await key('keyup', 'F3'); await sleep(300);
const hidden = await shot('hidden');
const back = region(closed, hidden, 8, 8, Math.min(400, w), 200);
console.log('after F3 again: ' + back + ' pixels differ from the first frame');
if (back > 200) problems.push('F3 again did not hide the overlay');

// the counters through app_frame_stats: 15 segments x 6 fields, then 6 counters x 3 fields, u64
const stats = await js(`(() => {
  const s = window.shell, rt = s.rt, p = rt.alloc((15 * 6 + 6 * 3) * 8);
  const frames = s.x.app_frame_stats(s.app, p);
  const v = new BigUint64Array(rt.mem().buffer ?? rt.mem(), Number(p), 15 * 6 + 6 * 3);
  const c = document.querySelector('canvas');
  return { frames, w: c.width, h: c.height, seg: Array.from(v.subarray(0, 90), Number), ctr: Array.from(v.subarray(90), Number) };
})()`);
const SEG = ['net', 'step', 'physics', 'scene', 'push', 'hud', 'draw', 'present', 'frame', 'ai', 'audio', 'gpu_shadow', 'gpu_scene', 'gpu_post', 'gpu_frame'];
const CTR = ['draw_calls', 'triangles', 'texture_bytes', 'particles', 'bodies', 'ai_agents'];
const seg = (n) => stats.seg.slice(SEG.indexOf(n) * 6, SEG.indexOf(n) * 6 + 6); // avg p50 p95 p99 max count
const ctr = (n) => stats.ctr.slice(CTR.indexOf(n) * 3, CTR.indexOf(n) * 3 + 3); // last avg max
console.log('frames in ring', stats.frames, 'canvas', stats.w + 'x' + stats.h);
for (const n of SEG) console.log('seg', n, JSON.stringify(seg(n)));
for (const n of CTR) console.log('ctr', n, JSON.stringify(ctr(n)));
if (stats.frames !== 300) problems.push(`the ring holds ${stats.frames} frames, not 300`);
if (ctr('bodies')[2] !== 9) problems.push(`bodies max ${ctr('bodies')[2]}, expected 9`);
if (ctr('draw_calls')[2] < 2) problems.push(`draw calls max ${ctr('draw_calls')[2]}, expected at least the primitive draw and the HUD`);
if (ctr('triangles')[2] < 9 * 384) problems.push(`triangles max ${ctr('triangles')[2]}, expected at least 9 * 384`);
const expectBytes = 22194848 + stats.w * stats.h * 4; // the texture array, atlas, environment and shadow map + the depth buffer
if (ctr('texture_bytes')[2] !== expectBytes) problems.push(`texture bytes ${ctr('texture_bytes')[2]}, expected ${expectBytes}`);
for (const n of ['gpu_shadow', 'gpu_scene', 'gpu_post', 'gpu_frame']) if (seg(n)[5] !== 0) problems.push(`${n} has ${seg(n)[5]} frames in a browser without timestamp queries`);
// ?offscreen draws on capture requests only, so `draw` ran in the frames that were captured, not in all 300
if (seg('draw')[5] < 10 || seg('frame')[5] !== 300) problems.push(`draw ran in ${seg('draw')[5]} frames and frame in ${seg('frame')[5]}`);
if (problems.length) { console.log('problems:\n  ' + problems.join('\n  ')); done(1); }
console.log('perf_overlay_shot: PASS');
done(0);
