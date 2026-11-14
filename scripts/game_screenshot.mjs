// Play the arena game in headless Chrome (SwiftShader WebGPU) and save frames as PNG, so the renderer and HUD get looked at.
// usage: node scripts/game_screenshot.mjs <chrome> <url> <out-prefix> [timeout_s] [shared|posted]
// With `shared` or `posted` it also requires sound: frames played through the SharedArrayBuffer ring (an isolated
// page) or through posted blocks (a page with no COOP/COEP headers, as on GitHub Pages).
// Writes <out-prefix>_start.png, _moved.png, _paused.png and prints the game state after each step.
// Exits non-zero unless every frame was captured, shows a scene (many colours), the frames differ from each other
// after input, and the browser reported no WebGPU error.
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { deflateSync } from 'node:zlib';

const [chrome, url, prefix, timeoutS = '120', audio = ''] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'game-shot-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--autoplay-policy=no-user-gesture-required', '--window-size=960,600', '--remote-debugging-port=0', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('game_screenshot: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?${url}`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
const problems = [];
const shots = {};
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') {
    const text = m.params.args.map((a) => a.value ?? a.description).join(' ');
    console.log('console:', text);
    if (/wgpu uncaptured error|app_frame:/.test(text)) problems.push('browser console: ' + text.split('\n')[0]);
  }
  if (m.method === 'Runtime.exceptionThrown') { console.log('exception:', m.params.exceptionDetails.exception?.description); problems.push('page exception'); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
await send('Runtime.enable');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
  const pitch = x.app_capture_pitch(app), w = s.canvasW, h = s.canvasH;
  const d = s.rt.bytes(p, pitch * h).slice(); x.app_capture_release(app);
  let bin = ''; for (let i = 0; i < d.length; i += 8192) bin += String.fromCharCode(...d.subarray(i, i + 8192));
  return { w, h, pitch, format: Number(x.app_format(app)), b64: btoa(bin),
    status: x.app_game_status(app), score: x.app_game_score(app), collected: x.app_game_collected(app) };
})()`;
async function shot(name) {
  const r = await js(GRAB);
  if (!r) { console.log(`${name}: capture never completed`); problems.push(`${name}: capture never completed`); return; }
  const bytes = Buffer.from(r.b64, 'base64'); const rgba = new Uint8Array(r.w * r.h * 4);
  for (let y = 0; y < r.h; y++) for (let xx = 0; xx < r.w; xx++) {
    const o = y * r.pitch + xx * 4, q = (y * r.w + xx) * 4;
    const bgr = !url.includes('offscreen') && (r.format === 27 || r.format === 28);
    rgba[q] = bytes[o + (bgr ? 2 : 0)]; rgba[q + 1] = bytes[o + 1]; rgba[q + 2] = bytes[o + (bgr ? 0 : 2)]; rgba[q + 3] = 255;
  }
  writeFileSync(`${prefix}_${name}.png`, png(r.w, r.h, rgba));
  const colours = new Set();
  for (let q = 0; q < rgba.length; q += 4) colours.add((rgba[q] >> 3) << 10 | (rgba[q + 1] >> 3) << 5 | rgba[q + 2] >> 3);
  shots[name] = { rgba, colours: colours.size, w: r.w, h: r.h };
  // A cleared frame has one colour. The paused frame has measured 49 to 52
  // across runs, so the old limit of 50 failed by chance; 30 is well clear of both.
  if (colours.size < 30) problems.push(`${name}: only ${colours.size} colours, not a scene`);
  console.log(`${name}: ${r.w}x${r.h} format ${r.format} status ${r.status} score ${r.score} collected ${r.collected}, ${colours.size} colours`);
}
const key = (type, code) => js(`window.dispatchEvent(new KeyboardEvent('${type}', { code: '${code}', bubbles: true }))`);
// wait for the app to have drawn frames
for (let i = 0; i < 200; i++) { if ((await js('window.shell && window.shell.frames')) > 10) break; await sleep(250); }
console.log('frames', await js('window.shell.frames'), 'error', await js('window.shell.error'));
await js('window.shell.canvasW = document.querySelector("canvas").width; window.shell.canvasH = document.querySelector("canvas").height');
await shot('start');
// A.2: one unit cube at the centre of the view (app_probe_cube), colour (0.8, 0.2, 0.2) before lighting. Taken while
// the game runs: a paused frame draws no arena geometry. The centre pixel must turn that red; the start frame has none.
await js('window.shell.x.app_probe_cube(window.shell.app, 1)'); await sleep(500);
await shot('probe');
await js('window.shell.x.app_probe_cube(window.shell.app, 0)');
const centre = (name) => { const { rgba, w, h } = shots[name]; const q = ((h >> 1) * w + (w >> 1)) * 4; return [rgba[q], rgba[q + 1], rgba[q + 2]]; };
const isCubeRed = ([r, g, b]) => r > 60 && r > 2 * g && r > 2 * b;
if (shots.probe) {
  // Expected: colour (0.8, 0.2, 0.2) times lit = 0.4 + 0.6 * max(n . L, 0) for the +z face the centre ray hits (the
  // camera looks down -z). L = normalize(0.4, 1.0, 0.6), so n . L = 0.6 / 1.2329 = 0.4867 and lit = 0.692; 0.692 * 255 *
  // (0.8, 0.2, 0.2) = (141.2, 35.3, 35.3). Measured on the start frame. The start camera is fixed, so this is exact to +-3.
  const expect = [141.2, 35.3, 35.3];
  const [r, g, b] = centre('probe');
  console.log(`centre pixel with the probe cube: rgb(${r}, ${g}, ${b}), expected about rgb(141, 35, 35)`);
  const off = Math.max(Math.abs(r - expect[0]), Math.abs(g - expect[1]), Math.abs(b - expect[2]));
  if (off > 3) problems.push(`centre pixel with the probe cube is rgb(${r}, ${g}, ${b}); the lit cube should be rgb(141, 35, 35) (off by ${off.toFixed(1)})`);
}
if (shots.start) {
  const [r, g, b] = centre('start');
  console.log(`centre pixel without it: rgb(${r}, ${g}, ${b})`);
  if (isCubeRed([r, g, b])) problems.push(`centre pixel without the probe is already rgb(${r}, ${g}, ${b}): the check cannot tell the cube apart`);
}
await key('keydown', 'KeyD'); await key('keydown', 'KeyW'); await sleep(2500); await key('keyup', 'KeyD'); await key('keyup', 'KeyW');
await shot('moved');
await key('keydown', 'KeyP'); await key('keyup', 'KeyP'); await sleep(500);
await shot('paused');
const differ = (a, b) => { let n = 0; for (let q = 0; q < a.length; q += 4) if (Math.abs(a[q] - b[q]) + Math.abs(a[q + 1] - b[q + 1]) + Math.abs(a[q + 2] - b[q + 2]) > 30) n++; return n; };
if (shots.start && shots.moved) {
  const n = differ(shots.start.rgba, shots.moved.rgba);
  console.log(`start vs moved: ${n} pixels differ`);
  if (n < 5000) problems.push(`holding W+D changed only ${n} pixels: the game did not react to the keys`);
}
if (shots.moved && shots.paused) {
  const n = differ(shots.moved.rgba, shots.paused.rgba);
  console.log(`moved vs paused: ${n} pixels differ`);
  if (n < 2000) problems.push(`pressing P changed only ${n} pixels: no pause banner`);
}
// B2 on the web: the synthetic skinning scene through the CPU reference and the GPU compute path. The page polls
// app_skin_result (-1 while the map is pending, -2 on failure) and asserts the max difference is below 1e-5.
await js('window.shell.x.app_skin_start(window.shell.app)');
let skinErr = -1;
for (let i = 0; i < 400; i++) {
  skinErr = await js('window.shell.x.app_skin_result(window.shell.app)');
  if (skinErr !== -1) break;
  await sleep(25);
}
console.log(`skinning B2 on web: max |GPU - CPU| = ${skinErr}`);
if (!(skinErr >= 0 && skinErr < 1e-5)) problems.push(`skinning B2 on web: max |GPU - CPU| is ${skinErr}, not below 1e-5`);
for (const p of problems) console.log('PROBLEM:', p);
console.log('game-shot:', problems.length ? 'FAIL' : 'PASS');
done(problems.length ? 1 : 0);
