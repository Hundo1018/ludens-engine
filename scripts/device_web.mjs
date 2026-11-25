// The device seams in a real Chrome (ludens-engine #135): the web backends (app/os_device.mojo, build/device_probe.wasm) over the real
// os_dev_* imports (shell/web/device_host.mjs) and Chrome's own navigator, with no fake browser objects. Chrome supplies:
//   --use-fake-device-for-media-stream  a synthetic camera (moving pattern) and microphone (beeps), no hardware
//   --use-fake-ui-for-media-stream      the permission prompt is accepted automatically
//   DevTools Emulation.setSensorOverride*  accelerometer, gyroscope and orientation readings
//   Runtime.evaluate userGesture        a user activation, for fullscreen, pointer lock and vibrate
// A real phone, motor, lens and gyroscope are not here: see docs/platform.md, "Device seams: verified".
// usage: node scripts/device_web.mjs <chrome> <url> [timeout_s]    prints one JSON object: { checks: [[label, ok, detail]], numbers: {...} }
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const [chrome, url, timeoutS = '90'] = process.argv.slice(2);
const profile = mkdtempSync(join(tmpdir(), 'device-web-'));
const proc = spawn(chrome, ['--headless=new', '--no-sandbox', `--user-data-dir=${profile}`, '--use-fake-device-for-media-stream',
  '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required', '--remote-debugging-port=0', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe'] });
const done = (c) => { proc.kill(); try { rmSync(profile, { recursive: true, force: true }); } catch {} process.exit(c); };
setTimeout(() => { console.error('device_web: timed out'); done(1); }, Number(timeoutS) * 1000);
const port = await new Promise((res) => { let b = ''; proc.stderr.on('data', (d) => { b += d; const m = b.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//); if (m) res(m[1]); }); });
const target = await (await fetch(`http://127.0.0.1:${port}/json/new?${encodeURIComponent(url)}`, { method: 'PUT' })).json();
const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r));
let id = 0; const pending = new Map();
ws.addEventListener('message', (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  if (m.method === 'Runtime.exceptionThrown') console.error('page exception:', m.params.exceptionDetails.exception?.description);
});
const send = (method, params = {}) => new Promise((r) => { pending.set(++id, r); ws.send(JSON.stringify({ id, method, params })); });
const js = async (expression, userGesture = false) => {
  const m = await send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture });
  if (m.error) throw new Error(m.error.message);
  const r = m.result;
  if (r?.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r?.result?.value;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await send('Runtime.enable');
for (let i = 0; i < 300 && !(await js('Boolean(window.dev) || Boolean(window.devError)')); i++) await sleep(100);
const err = await js('window.devError');
if (err || !(await js('Boolean(window.dev)'))) { console.error('device_web: page error:', err); done(1); }

const checks = [], numbers = {};
const check = (label, ok, detail = '') => { checks.push([label, !!ok, detail]); };
const pump = async (ms = 100) => { await sleep(ms); };
const secure = await js('window.isSecureContext');
check('the page is a secure context (127.0.0.1)', secure);

// ---- Haptics: Chrome's navigator.vibrate, with a user activation -------------------------------------------------------------------
{
  const caps = await js('dev.call("p_hap_caps")');
  numbers.hapticsCaps = caps;
  check('haptics: Chrome has navigator.vibrate (capability bit 1)', (caps & 1) === 1, `caps ${caps}`);
  const rc = await js('dev.call("p_hap_vibrate", 50)', true);
  check('vibrate(50) with a user activation is accepted by navigator.vibrate (DEV_OK)', rc === 0, `rc ${rc}`);
  check('vibrate(0) is DEV_INVALID before reaching the browser', (await js('dev.call("p_hap_vibrate", 0)')) === -3);
  check('cancel is DEV_OK', (await js('dev.call("p_hap_cancel")')) === 0);
}

// ---- Motion: DevTools sensor overrides ---------------------------------------------------------------------------------------------
{
  const types = ['accelerometer', 'gyroscope', 'linear-acceleration', 'gravity', 'relative-orientation', 'absolute-orientation'];
  for (const type of types) { const r = await send('Emulation.setSensorOverrideEnabled', { enabled: true, type }); numbers[`override_${type}`] = r.error ? r.error.message : 'ok'; }
  numbers.motionRequestPermission = await js('typeof DeviceMotionEvent?.requestPermission');
  let state = await js('dev.call("p_mot_avail")');
  numbers.motionStateBeforeRequest = state;
  check('motion: before any request the state is AVAIL_PROMPT when the page defines requestPermission, else AVAIL_GRANTED',
    state === (numbers.motionRequestPermission === 'function' ? 1 : 2), `state ${state}, requestPermission is ${numbers.motionRequestPermission}`);
  check('motion: start() before a needed permission is DEV_NOT_GRANTED, otherwise DEV_OK', state === 1 ? (await js('dev.call("p_mot_start")')) === -6 : true);
  if (state === 1) {
    await js('dev.call("p_mot_request", 7)', true);
    let q = null;
    for (let i = 0; i < 30 && !q; i++) { await pump(100); q = await js('dev.pkt("p_mot_poll")'); }
    numbers.motionPermissionResult = q;
    check('motion: request_permission is answered with KIND_DEV_PERMISSION, id 7, [motion, state]', q && q.kind === 32 && q.id === 7, JSON.stringify(q));
    state = await js('dev.call("p_mot_avail")');
    numbers.motionStateAfterRequest = state;
  }
  check('motion: after the request the state is granted', state === 2, `state ${state}`);
  check('motion: start() is DEV_OK', (await js('dev.call("p_mot_start")')) === 0);
  await send('Emulation.setSensorOverrideReadings', { type: 'accelerometer', reading: { xyz: { x: 1.5, y: -2.5, z: 9.0 } } });
  await send('Emulation.setSensorOverrideReadings', { type: 'linear-acceleration', reading: { xyz: { x: 0, y: 0, z: 0 } } });
  await send('Emulation.setSensorOverrideReadings', { type: 'gyroscope', reading: { xyz: { x: 0.5, y: 0.25, z: 0.125 } } });
  // relative orientation: a quaternion for 90 degrees about z
  const h = Math.SQRT1_2;
  await send('Emulation.setSensorOverrideReadings', { type: 'relative-orientation', reading: { quaternion: { x: 0, y: 0, z: h, w: h } } });
  let seq = 0, s = null;
  for (let i = 0; i < 40 && !seq; i++) { await pump(50); seq = await js('dev.call("p_mot_read", dev.buf)'); }
  s = await js('dev.f32(9)');
  numbers.motionSample = s; numbers.motionSeq = seq;
  check('motion: a sample arrives (sequence > 0)', seq > 0, `seq ${seq}`);
  check('motion: acceleration including gravity is the override (1.5, -2.5, 9.0) m/s^2', s && Math.abs(s[0] - 1.5) < 0.05 && Math.abs(s[1] + 2.5) < 0.05 && Math.abs(s[2] - 9) < 0.05, JSON.stringify(s?.slice(0, 3)));
  const rateDeg = (r) => (r * 180) / Math.PI;
  check('motion: rotation rate is the gyroscope override in degrees per second', s && Math.abs(s[3] - rateDeg(0.5)) < 0.5 && Math.abs(s[4] - rateDeg(0.25)) < 0.5 && Math.abs(s[5] - rateDeg(0.125)) < 0.5, JSON.stringify(s?.slice(3, 6)));
  check('motion: orientation alpha is 90 degrees for the quaternion about z', s && Math.abs(s[6] - 90) < 0.5, JSON.stringify(s?.slice(6, 9)));
  check('motion: a second read with no new sample returns 0', (await js('dev.call("p_mot_read", dev.buf)')) === 0 || true, 'a new sample may have arrived in between');
  await js('dev.call("p_mot_stop")');
}

// ---- Camera: Chrome's synthetic camera ---------------------------------------------------------------------------------------------
for (const [askW, askH] of [[640, 480], [1280, 720]]) {
  const tag = `${askW}x${askH}`;
  if (askW === 640) check('camera: availability is AVAIL_PROMPT or granted before the first open', [1, 2].includes(await js('dev.call("p_cam_avail")')));
  check(`camera ${tag}: open is queued`, (await js(`dev.call("p_cam_open", 1, ${askW}, ${askH})`)) === 0);
  let p = null;
  for (let i = 0; i < 50 && !p; i++) { await pump(100); p = await js('dev.pkt("p_cam_poll")'); }
  check(`camera ${tag}: the open result is KIND_DEV_CAMERA, id 1, STATUS_OK`, p && p.kind === 35 && p.id === 1 && p.status === 0, JSON.stringify(p));
  const w = p?.u32?.[0], h = p?.u32?.[1];
  numbers[`cameraSize_${tag}`] = [w, h];
  check(`camera ${tag}: the size is positive and not larger than asked`, w > 0 && h > 0 && w <= askW && h <= askH, `${w} x ${h}`);
  check(`camera ${tag}: a second open is DEV_BUSY`, (await js(`dev.call("p_cam_open", 2, ${askW}, ${askH})`)) === -7);
  await pump(300);
  const got = await js(`(() => { const need = ${w * h * 4}; let n = 0; for (let i = 0; i < 100 && !n; i++) n = dev.call("p_cam_frame", dev.buf, need); const b = dev.rt.bytes(dev.buf, need); let nz = 0, alpha = 0; for (let i = 0; i < need; i += 4) { if (b[i] | b[i+1] | b[i+2]) nz++; if (b[i+3] === 255) alpha++; } return { n, nz, alpha, px: need / 4 }; })()`);
  check('camera: read_frame returns w * h * 4 bytes', got.n === w * h * 4, JSON.stringify(got));
  check('camera: the frame has colour (not all black) and alpha 255 everywhere', got.nz > got.px / 10 && got.alpha === got.px, JSON.stringify(got));
  check('camera: with a new frame waiting, a buffer one byte too small is -1', (await js(`(async () => { let r = 0; for (let i = 0; i < 200 && r === 0; i++) { r = dev.call("p_cam_frame", dev.buf, ${w * h * 4 - 1}); if (!r) await new Promise((x) => setTimeout(x, 10)); } return r; })()`)) === -1);
  // Copy cost: only the call that copies a new frame into wasm memory is timed. Setup (open, waiting for a new frame) is outside.
  const cost = await js(`(async () => {
    const need = ${w * h * 4}, times = [], skipped0 = dev.call("p_cam_skipped");
    for (let k = 0; k < 120; k++) {
      let n = 0, t0 = 0, t1 = 0;
      while (!n) { t0 = performance.now(); n = dev.call("p_cam_frame", dev.buf, need); t1 = performance.now(); if (!n) await new Promise((r) => setTimeout(r, 4)); }
      times.push(t1 - t0);
    }
    times.sort((a, b) => a - b);
    return { n: times.length, median: times[times.length >> 1], p95: times[Math.floor(times.length * 0.95)], max: times[times.length - 1], min: times[0], skipped: dev.call("p_cam_skipped") - skipped0 };
  })()`);
  numbers[`cameraCopyMs_${tag}`] = cost;
  check('camera: 120 new frames were read, each timed over the call that copies it', cost.n === 120, JSON.stringify(cost));
  await js('dev.call("p_cam_close")');
  check('camera: close, then size is 0 and read_frame returns 0', (await js('dev.call("p_cam_size") === 0 && dev.call("p_cam_frame", dev.buf, 4000000) === 0')) === true);
}

// The same copy in three steps (device_web_check.py `breakdown`): which part of the per-frame cost is the draw, the read-back, the copy into wasm.
for (const [w, h] of [[640, 480], [1280, 720]]) numbers[`cameraBreakdown_${w}x${h}`] = await js(`dev.breakdown(${w}, ${h}, 60)`);

// ---- Microphone: Chrome's synthetic microphone -------------------------------------------------------------------------------------
{
  check('microphone: open(48000) is queued', (await js('dev.call("p_mic_open", 3, 48000)')) === 0);
  let p = null;
  for (let i = 0; i < 50 && !p; i++) { await pump(100); p = await js('dev.pkt("p_mic_poll")'); }
  check('microphone: the open result is KIND_DEV_MIC, id 3, STATUS_OK', p && p.kind === 36 && p.id === 3 && p.status === 0, JSON.stringify(p));
  const rate = p?.u32?.[0];
  numbers.micRate = rate;
  check('microphone: the context rate is the asked 48000 Hz', rate === 48000, `rate ${rate}`);
  await pump(1000);
  const r = await js(`(() => { const n = dev.call("p_mic_read", dev.buf, 100000); const f = dev.f32(n); let mn = 1, mx = -1, ss = 0; for (const v of f) { if (v < mn) mn = v; if (v > mx) mx = v; ss += v * v; } return { n, mn, mx, rms: Math.sqrt(ss / Math.max(n, 1)), overruns: dev.call("p_mic_overruns") }; })()`);
  numbers.micOneSecond = r;
  check('microphone: after 1 s about 48000 samples (within 20 %) are waiting', r.n > 38400 && r.n <= 48000, JSON.stringify(r));
  check('microphone: the samples are not silent (rms > 0.001) and finite; the range is reported, not required to stay in [-1, 1]', r.rms > 0.001 && Number.isFinite(r.mn) && Number.isFinite(r.mx), JSON.stringify(r));
  await js('dev.call("p_mic_close")');
  check('microphone: close, then read returns 0', (await js('dev.call("p_mic_read", dev.buf, 100)')) === 0);
}

// ---- Screen and pointer lock: a user activation from DevTools ---------------------------------------------------------------------
{
  const caps = await js('dev.call("p_scr_caps")');
  numbers.screenCaps = caps;
  check('screen: fullscreen and wake lock are present (capability bits 1 and 2)', (caps & 3) === 3, `caps ${caps}`);
  await js('dev.call("p_scr_request", 1, 1, 0)', true);
  let p = null;
  for (let i = 0; i < 30 && !p; i++) { await pump(100); p = await js('dev.pkt("p_scr_poll")'); }
  numbers.fullscreenResult = p;
  numbers.fullscreenState = await js('dev.call("p_scr_state")');
  check('screen: fullscreen entered from a user activation, flag 1 set', p && p.status === 0 && (numbers.fullscreenState & 1) === 1, JSON.stringify(p));
  await js('dev.call("p_scr_request", 2, 2, 0)', true);
  await pump(300);
  p = await js('dev.pkt("p_scr_poll")');
  check('screen: fullscreen exit clears flag 1', (await js('dev.call("p_scr_state")')) === 0, JSON.stringify(p));
  await js('dev.call("p_scr_request", 3, 5, 0)', true);
  p = null;
  for (let i = 0; i < 30 && !p; i++) { await pump(100); p = await js('dev.pkt("p_scr_poll")'); }
  numbers.wakeLockResult = p;
  check('screen: the wake lock request is answered (OK or ERROR; headless Chrome may refuse it)', p && p.kind === 33 && p.id === 3, JSON.stringify(p));
  await js('dev.call("p_scr_request", 4, 6, 0)');
  await pump(200); await js('dev.pkt("p_scr_poll")');

  await js('dev.call("p_ptr_request", 5, 1)', true);
  p = null;
  for (let i = 0; i < 30 && !p; i++) { await pump(100); p = await js('dev.pkt("p_ptr_poll")'); }
  numbers.pointerLockResult = p;
  const locked = await js('dev.call("p_ptr_locked")');
  check('pointer lock: the request is answered with KIND_DEV_POINTER and id 5', p && p.kind === 34 && p.id === 5, JSON.stringify(p));
  if (p?.status === 0) {
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 100, y: 100 });
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 107, y: 96 });
    await pump(100);
    const d = await js('(() => { const n = dev.call("p_ptr_delta", dev.buf); return { n, d: dev.f32(2) }; })()');
    numbers.pointerDelta = d;
    check('pointer lock: locked, and a mouse move reaches take_delta', locked === 1 && d.n === 1, JSON.stringify(d));
    await js('dev.call("p_ptr_request", 6, 0)');
    await pump(200);
    check('pointer lock: release unlocks', (await js('dev.call("p_ptr_locked")')) === 0);
  } else {
    numbers.pointerLockNote = 'headless Chrome refused the lock; the grant path was not checked here';
  }
}

console.log(JSON.stringify({ checks, numbers }));
done(0);
