// The live tuning panel in headless Chrome (SwiftShader WebGPU): F2 opens it, a pointer drag on the speed slider and a
// click on Export, then the downloaded table file is read back. Writes <out-prefix>_closed.png and _open.png.
// usage: node scripts/tuning_shot.mjs <chrome> <url> <out-prefix> [timeout_s]
// Exits non-zero unless: the panel changes the frame, the drag queues a speed inside the slider's range at the pointer's
// position, Export offers one download named demo.table whose speed row holds that value, and nothing else in the
// file changed.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';

const [chrome, url, prefix, timeoutS = '120'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'tuning-shot-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=700,500', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('tuning_shot: timed out'); done(1); }, Number(timeoutS) * 1000);
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
    if (/wgpu uncaptured error|app_frame:/.test(text)) problems.push('browser console: ' + text.split('\n')[0]);
  }
  if (m.method === 'Runtime.exceptionThrown') { console.log('exception:', m.params.exceptionDetails.exception?.description); problems.push('page exception'); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await send('Runtime.enable');

function png(w, h, rgba) {
  const crcT = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
  const crc = (b) => { let c = 0xffffffff; for (const x of b) c = crcT[(c ^ x) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
  const chunk = (t, d) => { const b = Buffer.alloc(12 + d.length); b.writeUInt32BE(d.length, 0); b.write(t, 4); d.copy(b, 8); b.writeUInt32BE(crc(b.subarray(4, 8 + d.length)), 8 + d.length); return b; };
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (w * 4 + 1)] = 0; Buffer.from(rgba.buffer, rgba.byteOffset + y * w * 4, w * 4).copy(raw, y * (w * 4 + 1) + 1); }
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
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
  const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
  for (let y = 0; y < r.h; y++) for (let x = 0; x < r.w; x++) {
    const o = y * r.pitch + x * 4, q = (y * r.w + x) * 4;
    rgba[q] = bytes[o]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + 2]; rgba[q + 3] = 255;
  }
  writeFileSync(`${prefix}_${name}.png`, png(r.w, r.h, rgba));
  return { rgba, w: r.w, h: r.h };
}
// The app draws (and so runs the panel) only when a capture is requested in this headless mode: one capture per pointer step.
const settle = async () => { await js(GRAB); };
const mouse = (type, x, y) => send('Input.dispatchMouseEvent', { type, x, y, button: 'left', buttons: type === 'mouseReleased' ? 0 : 1, clickCount: 1 });

for (let i = 0; i < 200; i++) { if ((await js('window.shell && window.shell.frames')) > 10) break; await sleep(250); }
console.log('frames', await js('window.shell.frames'), 'error', await js('window.shell.error'));
// record the downloads the page offers: name and text
await js(`window.__files = []; HTMLAnchorElement.prototype.click = function () { const n = this.download, u = this.href; fetch(u).then((r) => r.text()).then((t) => window.__files.push({ name: n, text: t })); };`);
const closed = await shot('closed');
await js(`window.dispatchEvent(new KeyboardEvent('keydown', { code: 'F2', bubbles: true }))`);
const hold = shot('held');  // a capture while F2 is down: the app draws on capture requests only
await hold;
await js(`window.dispatchEvent(new KeyboardEvent('keyup', { code: 'F2', bubbles: true }))`);
await sleep(800);
const open = await shot('open');
let changed = 0;
if (closed && open) for (let y = 40; y < 260; y++) for (let x = 8; x < 428; x++) { const q = (y * open.w + x) * 4; if (Math.abs(open.rgba[q] - closed.rgba[q]) + Math.abs(open.rgba[q + 1] - closed.rgba[q + 1]) + Math.abs(open.rgba[q + 2] - closed.rgba[q + 2]) > 60) changed++; }
console.log('panel region: ' + changed + ' of ' + (220 * 420) + ' pixels differ from the closed frame');
if (changed < 2000) problems.push('F2 did not draw the panel');
// canvas coordinates -> viewport coordinates (the page may show the canvas scaled)
const box = await js(`(() => { const r = document.querySelector('canvas').getBoundingClientRect(); return { l: r.left, t: r.top, sx: r.width / document.querySelector('canvas').width, sy: r.height / document.querySelector('canvas').height }; })()`);
console.log('canvas box', JSON.stringify(box));
const at = (cx, cy) => [box.l + cx * box.sx, box.t + cy * box.sy];
const SLIDER_Y = 40 + 6 + 22 + 6 + 22 + 11, SLIDER_X0 = 8 + 6 + 408 * 0.6, SLIDER_W = 408 * 0.4; // panel at x = 8, 420 wide (game/demo_mode.mojo)
const target_t = 0.5; // the pointer at the middle of the slider
let [px, py] = at(SLIDER_X0 + SLIDER_W * 0.3, SLIDER_Y);
await mouse('mouseMoved', px, py); await settle();
await mouse('mousePressed', px, py); await settle();
[px, py] = at(SLIDER_X0 + SLIDER_W * target_t, SLIDER_Y);
await mouse('mouseMoved', px, py); await settle(); await settle();
await mouse('mouseReleased', px, py); await settle();
const dragged = await shot('dragged');
// Export button
[px, py] = at(8 + 420 - 6 - 408 * 0.15, 40 + 6 + 11);
await mouse('mouseMoved', px, py); await settle();
await mouse('mousePressed', px, py); await settle();
await mouse('mouseReleased', px, py); await settle(); await sleep(500);
const files = await js('window.__files');
console.log('downloads:', JSON.stringify(files));
if (!files || files.length !== 1) problems.push('expected one download, got ' + (files ? files.length : 'none'));
else {
  const f = files[0];
  if (f.name !== 'demo.table') problems.push('download name ' + f.name);
  const m = f.text.match(/^demo\.main\.speed = ([0-9.]+)$/m);
  const want = 0.5 + 19.5 * target_t;
  if (!m) problems.push('the exported table has no speed row');
  else if (Math.abs(Number(m[1]) - want) > 0.3) problems.push(`speed ${m[1]} is not near ${want} (the slider position)`);
  else console.log(`exported speed ${m[1]} for a slider position of ${target_t} (${want} expected)`);
  const rest = f.text.split('\n').filter((l) => !l.startsWith('demo.main.speed')).join('\n');
  const orig = 'ludens-table 1 schema 1\n# One entry, every value at its schema default: the game plays as it did before the table existed.\ndemo.main = +\n';
  if (rest !== orig) problems.push('the exported file changed rows other than speed:\n' + f.text);
}
if (await js('window.shell.error')) problems.push('page error: ' + (await js('window.shell.error')));
if (problems.length) { console.log('FAIL:\n  ' + problems.join('\n  ')); done(1); }
console.log('tuning_shot: ok');
done(0);
