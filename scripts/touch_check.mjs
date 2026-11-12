// Play the arena game by touch only, in headless Chrome emulating a phone, and check the virtual pad (shell/web/vpad*.ts).
// usage: node scripts/touch_check.mjs <chrome> <url> <out-prefix> [timeout_s]
// Touches are sent with the DevTools Input.dispatchTouchEvent, so they are trusted events with pointer capture and user
// activation, and Chrome is started WITHOUT an autoplay override: the sound check means a touch really started it.
// Landscape (844x390): the controls are shown and inside the viewport; the left thumb holds the stick up while a second
// finger taps Jump; a drag on the canvas turns the camera; Pause is tapped. The frames must change, the pad must have
// sent exactly those keys, and audio must be running from one start. Portrait (390x844): the layout is checked again.
// Writes <out-prefix>_landscape.png and <out-prefix>_portrait.png (the page as a phone shows it).
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, prefix, timeoutS = '150'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'touch-check-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', '--disable-gpu-sandbox', `--user-data-dir=${profile}`,
  '--enable-unsafe-webgpu', '--enable-unsafe-swiftshader', '--use-webgpu-adapter=swiftshader',
  '--window-size=844,390', '--remote-debugging-port=0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.log('touch_check: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
const problems = [];
const need = (cond, what) => { console.log(`  [${cond ? 'PASS' : 'FAIL'}] ${what}`); if (!cond) problems.push(what); };
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') {
    const text = m.params.args.map((a) => a.value ?? a.description).join(' ');
    if (/wgpu uncaptured error|app_frame:/.test(text)) problems.push('browser console: ' + text.split('\n')[0]);
  }
  if (m.method === 'Runtime.exceptionThrown') { console.log('exception:', m.params.exceptionDetails.exception?.description); problems.push('page exception'); }
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression) => (await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true }))?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const phone = (width, height) => send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 2, mobile: true });
const touch = (type, points) => send('Input.dispatchTouchEvent', { type, touchPoints: points.map(([x, y, id], i) => ({ x, y, id: id ?? i })) });
// touchEnd names the fingers that are lifted (an empty list lifts all of them); the others stay down.
const screenshot = async (name) => writeFileSync(`${prefix}_${name}.png`, Buffer.from((await send('Page.captureScreenshot', { format: 'png' })).data, 'base64'));

await send('Runtime.enable');
await send('Page.enable');
await phone(844, 390);
await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
await send('Page.navigate', { url });
for (let i = 0; i < 200; i++) { if ((await js('window.shell && window.shell.frames')) > 10) break; await sleep(250); }
console.log('frames', await js('window.shell && window.shell.frames'), 'error', await js('window.shell && window.shell.error'));

// One frame's pixels, read back from the app (the canvas itself is not drawn to in headless Chrome: ?offscreen).
const GRAB = `(async () => {
  const s = window.shell, x = s.x, app = s.app, c = document.querySelector('canvas');
  x.app_request_capture(app);
  for (let i = 0; i < 900 && x.app_capture_ptr(app) === 0n; i++) await new Promise((r) => requestAnimationFrame(r));
  const p = x.app_capture_ptr(app); if (p === 0n) return null;
  const pitch = x.app_capture_pitch(app);
  const d = s.rt.bytes(p, pitch * c.height); let sum = [];
  for (let y = 0; y < c.height; y += 4) for (let xx = 0; xx < c.width; xx += 4) { const o = y * pitch + xx * 4; sum.push(d[o], d[o + 1], d[o + 2]); }
  x.app_capture_release(app);
  return sum;
})()`;
const differ = (a, b) => { let n = 0; for (let q = 0; q < a.length; q += 3) if (Math.abs(a[q] - b[q]) + Math.abs(a[q + 1] - b[q + 1]) + Math.abs(a[q + 2] - b[q + 2]) > 30) n++; return n; };
const LAYOUT = `JSON.stringify((() => {
  const r = (e) => { const b = e.getBoundingClientRect(); return { l: b.left, t: b.top, r: b.right, b: b.bottom }; };
  const q = (s) => document.querySelector(s);
  return { shown: !!q('.vpad.on'), touchClass: document.documentElement.classList.contains('touch'), vw: innerWidth, vh: innerHeight,
    canvas: r(q('canvas')), zone: r(q('[data-stick=move]')), base: r(q('[data-stick=move] .vpad-base')),
    jump: r(q('[data-button=jump]')), pause: r(q('[data-button=pause]')), restart: r(q('[data-button=restart]')),
    hint: getComputedStyle(q('.for-touch')).display, keysHint: getComputedStyle(q('.for-keys')).display };
})())`;
const inside = (b, L) => b.l >= 0 && b.t >= 0 && b.r <= L.vw + 0.5 && b.b <= L.vh + 0.5;
const apart = (a, b) => a.r <= b.l || b.r <= a.l || a.b <= b.t || b.b <= a.t;
const mid = (b) => [Math.round((b.l + b.r) / 2), Math.round((b.t + b.b) / 2)];
function checkLayout(L, name) {
  need(L.shown && L.touchClass, `${name}: the pad is shown on a touch device`);
  need(L.hint === 'block' && L.keysHint === 'none', `${name}: the page shows the touch instructions, not the keyboard ones`);
  need(L.canvas.r - L.canvas.l <= L.vw + 0.5 && L.canvas.b - L.canvas.t <= L.vh + 0.5, `${name}: the canvas fits the viewport (${Math.round(L.canvas.r - L.canvas.l)}x${Math.round(L.canvas.b - L.canvas.t)} in ${L.vw}x${L.vh})`);
  need(Math.abs((L.canvas.r - L.canvas.l) / (L.canvas.b - L.canvas.t) - 16 / 9) < 0.02, `${name}: the canvas keeps 16:9`);
  for (const k of ['base', 'jump', 'pause', 'restart']) need(inside(L[k], L), `${name}: ${k} is inside the viewport`);
  need(apart(L.jump, L.zone) && apart(L.pause, L.zone) && apart(L.restart, L.zone) && apart(L.pause, L.restart) && apart(L.jump, L.pause),
    `${name}: no two controls overlap`);
  need(L.jump.r - L.jump.l >= 44 && L.pause.r - L.pause.l >= 44, `${name}: buttons are at least 44 px across`);
}

const L = JSON.parse(await js(LAYOUT));
checkLayout(L, 'landscape');
const start = await js(GRAB);
need(!!start, 'a frame was captured');

// left thumb lands in the zone away from the resting stick and pushes up; a second finger taps Jump while it is held
const thumb = [Math.round(L.zone.l + 150), Math.round(L.zone.b - 110)];
const up = [thumb[0], thumb[1] - 70];
const jump = mid(L.jump);
await touch('touchStart', [thumb]);
const landed = JSON.parse(await js(`JSON.stringify((() => { const b = document.querySelector('[data-stick=move] .vpad-base').getBoundingClientRect(); return [(b.left + b.right) / 2, (b.top + b.bottom) / 2]; })())`));
need(Math.abs(landed[0] - thumb[0]) < 2 && Math.abs(landed[1] - thumb[1]) < 2, `the stick centres where the thumb landed (${landed.map(Math.round)} for a touch at ${thumb})`);
await touch('touchMove', [up]);
await sleep(300);
await touch('touchStart', [up, jump]);
await sleep(120);
await touch('touchEnd', [[...jump, 1]]);
await sleep(2200);
await screenshot('landscape');
const moved = await js(GRAB);
await touch('touchEnd', []);
// a drag on the canvas, above the stick zone and left of the buttons
const lookFrom = [Math.round(L.vw * 0.62), Math.round(L.vh * 0.3)];
await touch('touchStart', [lookFrom]);
await touch('touchMove', [[lookFrom[0] - 40, lookFrom[1]]]);
await touch('touchMove', [[lookFrom[0] - 80, lookFrom[1] + 10]]);
await touch('touchEnd', []);
await sleep(300);
await touch('touchStart', [mid(L.pause)]);
await sleep(80);
await touch('touchEnd', []);
await sleep(600);
const paused = await js(GRAB);
await sleep(600);

const log = JSON.parse(await js('JSON.stringify(window.shell.padLog)'));
const keys = log.filter((e) => /^[+-]\d/.test(e)).join(' ');
console.log('pad sent:', log.join(' '));
need(keys === '+87 +32 -32 -87 +80 -80', `keys: W held, Space tapped while it is held, W released, P tapped (got: ${keys})`);
need(log.filter((e) => e === 'look').length === 2 && log.filter((e) => e === 'end').length === 1, 'the canvas drag turned the camera twice and ended once');
if (start && moved) { const n = differ(start, moved); need(n > 300, `holding the stick changed the picture (${n} of ${start.length / 3} sampled pixels)`); }
if (moved && paused) { const n = differ(moved, paused); need(n > 120, `tapping II changed the picture (${n} sampled pixels)`); }
const a = JSON.parse(await js('JSON.stringify({ starts: window.shell.audioStarts, played: window.shell.played, rendered: window.shell.rendered, state: window.shell.audio ? window.shell.audio.ctx.state : "none", error: window.shell.error })'));
console.log(`audio: starts ${a.starts}, state ${a.state}, rendered ${a.rendered}, played ${a.played}`);
need(a.error === '', `no page error (${a.error})`);
need(a.starts === 1 && a.state === 'running', 'touch alone started audio, once, and the context is running');
need(a.played > 24000, `sound was played (${a.played} frames; 48000 a second)`);

await phone(390, 844);
await sleep(500);
checkLayout(JSON.parse(await js(LAYOUT)), 'portrait');
await screenshot('portrait');

console.log(problems.length ? `touch-check: FAIL\n  ${problems.join('\n  ')}` : 'touch-check: PASS');
done(problems.length ? 1 : 0);
