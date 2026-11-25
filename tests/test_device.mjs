// The device seams over the real os_dev_* imports (ludens-engine #135): the web backends in app/os_device.mojo, compiled to wasm64
// (app/device_probe.mojo), against fake browser objects. The same contract tests/platform_device.mojo checks on the memory
// backends: argument limits, permission states and their result packets, reads that return 0 when nothing is new.
// What this cannot show: that a real browser, phone or camera behaves like the fakes (see docs/platform.md, "Device seams: verified").
// usage: node tests/test_device.mjs build/device_probe.wasm <ludens-wasm-rt host.mjs> <wgpu-mojo dir> <miniaudio-mojo dir>
const [wasm, hostMjs, wgpuDir, maDir] = process.argv.slice(2);
const { bootApp } = await import(new URL("../scripts/node_app.mjs", import.meta.url));
const { sampleRing } = await import(new URL("../shell/web/device_host.mjs", import.meta.url));
let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const tick = async () => { for (let i = 0; i < 4; i++) await new Promise((r) => setTimeout(r, 0)); };

const UNSUP = 0, PROMPT = 1, GRANTED = 2, DENIED = 3;
const KIND_PERM = 32, KIND_SCREEN = 33, KIND_POINTER = 34, KIND_CAMERA = 35, KIND_MIC = 36;

/** A tiny EventTarget: addEventListener, removeEventListener, dispatch. */
function targets() {
  const l = new Map();
  return {
    addEventListener: (n, f) => { if (!l.has(n)) l.set(n, new Set()); l.get(n).add(f); },
    removeEventListener: (n, f) => l.get(n)?.delete(f),
    dispatch: (n, e = {}) => { for (const f of l.get(n) ?? []) f(e); },
    count: (n) => l.get(n)?.size ?? 0,
  };
}

/** Fake browser objects. `o` turns features off or answers prompts. */
function fakeDevice(o = {}) {
  const log = { vibrate: [], rumble: [], getUserMedia: 0, lockOrient: [], wake: 0, fullscreen: 0 };
  const win = Object.assign(targets(), {});
  if (o.motion !== false) { win.DeviceMotionEvent = function () {}; win.DeviceOrientationEvent = function () {}; }
  if (o.iosMotion) {
    win.DeviceMotionEvent.requestPermission = async () => (o.iosAnswer === false ? "denied" : "granted");
    win.DeviceOrientationEvent.requestPermission = async () => (o.iosAnswer === false ? "denied" : "granted");
  }
  const doc = Object.assign(targets(), {
    fullscreenElement: null, pointerLockElement: null,
    documentElement: {
      requestFullscreen: async () => { if (!o.activation) throw new Error("NotAllowedError"); doc.fullscreenElement = doc.documentElement; log.fullscreen++; },
      requestPointerLock: () => { if (o.activation) { doc.pointerLockElement = doc.documentElement; Promise.resolve().then(() => doc.dispatch("pointerlockchange")); } else Promise.resolve().then(() => doc.dispatch("pointerlockerror")); },
    },
    exitFullscreen: async () => { doc.fullscreenElement = null; },
    exitPointerLock: () => { doc.pointerLockElement = null; Promise.resolve().then(() => doc.dispatch("pointerlockchange")); },
    querySelector: () => null,
  });
  const pad = { vibrationActuator: { playEffect: async (t, p) => { log.rumble.push([t, p]); }, reset: async () => { log.rumble.push(["reset"]); } } };
  const nav = {
    userAgent: o.ua ?? "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/158.0.0.0 Mobile Safari/537.36",
    getGamepads: () => (o.pad === false ? [null] : [pad]),
    mediaDevices: o.media === false ? undefined : { getUserMedia: async () => { log.getUserMedia++; if (o.userSays === false) { const e = new Error("no"); e.name = "NotAllowedError"; throw e; } return { getTracks: () => [{ stop() {} }] }; } },
    wakeLock: o.wake === false ? undefined : { request: async () => { log.wake++; return Object.assign(targets(), { released: false, release: async function () { this.released = true; } }); } },
  };
  if (o.vibrate !== false) nav.vibrate = (p) => { log.vibrate.push(p); return true; };
  const screen = { orientation: o.orient === false ? undefined : { lock: async (n) => { if (!doc.fullscreenElement) throw new Error("SecurityError"); log.lockOrient.push(n); }, unlock() { log.lockOrient.push("unlock"); } } };
  const cams = [], mics = [];
  return {
    log, win, doc, nav, cams, mics,
    device: {
      navigator: nav, document: doc, screen, window: win, isSecure: o.secure !== false,
      openCamera: async (w, h) => {
        if (o.userSays === false) { const e = new Error("no"); e.name = "NotAllowedError"; throw e; }
        const width = Math.min(w, 1280), height = Math.min(h, 720);
        const c = { width, height, seq: 0, closed: false, frameSeq: () => c.seq, copyTo(dst) { for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) { const k = (y * width + x) * 4; dst[k] = (x + c.seed) & 255; dst[k + 1] = (y + 2 * c.seed) & 255; dst[k + 2] = (x + y) & 255; dst[k + 3] = 255; } }, close() { c.closed = true; }, seed: 0 };
        cams.push(c); return c;
      },
      openMic: async (rate) => {
        if (o.userSays === false) { const e = new Error("no"); e.name = "NotAllowedError"; throw e; }
        const ring = sampleRing(o.micRate ?? rate);
        const m = { rate: o.micRate ?? rate, push: ring.push, read: ring.read, overruns: ring.overruns, close() { m.closed = true; } };
        mics.push(m); return m;
      },
    },
  };
}

async function boot(o) {
  const f = fakeDevice(o);
  const { rt, os } = await bootApp({ wasm, hostMjs, wgpuDir, maDir, device: f.device });
  const h = rt.call("p_new");
  const buf = rt.alloc(1 << 20);
  const call = (n, ...a) => rt.call(n, h, ...a);
  const f32 = (n, at = 0) => { const b = rt.bytes(buf + BigInt(at), n * 4); const v = new DataView(b.buffer, b.byteOffset, n * 4); return Array.from({ length: n }, (_, i) => v.getFloat32(4 * i, true)); };
  const pkt = (poller, cap = 256) => {
    const n = call(poller, buf, cap);
    if (n <= 0) return { n };
    const b = rt.bytes(buf, n), v = new DataView(b.buffer, b.byteOffset, n);
    return { n, kind: b[0], id: v.getUint32(1, true), status: b[5], payload: Array.from(b.slice(6)), u32: (at) => v.getUint32(6 + at, true) };
  };
  return { f, rt, os, h, buf, call, f32, pkt };
}

// ---- Haptics -------------------------------------------------------------------------------------------------------------
console.log("Haptics");
{
  const t = await boot();
  const pat = (...v) => { const b = rt_bytes(t, v.length * 2); v.forEach((x, i) => { b[2 * i] = x & 255; b[2 * i + 1] = x >> 8; }); return t.buf; };
  check(t.call("p_hap_avail") === GRANTED && t.call("p_hap_caps") === 3, "phone with a gamepad: granted, vibrate and rumble");
  check(t.call("p_hap_vibrate", 50) === 0 && t.f.log.vibrate.at(-1) === 50, "vibrate(50) reaches navigator.vibrate(50)");
  check(t.call("p_hap_vibrate", 0) === -3 && t.call("p_hap_vibrate", 5001) === -3 && t.call("p_hap_vibrate", -3) === -3, "vibrate(0), vibrate(5001), vibrate(-3) are DEV_INVALID");
  check(t.f.log.vibrate.length === 1, "the refused calls did not reach the browser");
  check(t.call("p_hap_pattern", pat(100, 50, 200), 3) === 0 && JSON.stringify(t.f.log.vibrate.at(-1)) === "[100,50,200]", "a pattern of 100 on, 50 off, 200 on reaches the browser in order");
  check(t.call("p_hap_pattern", pat(10, 6000), 2) === -3 && t.call("p_hap_pattern", pat(10), 0) === -3 && t.call("p_hap_pattern", pat(10), 33) === -3, "an entry over 5000, 0 entries, 33 entries are DEV_INVALID");
  check(t.call("p_hap_rumble", 0, 255, 128, 300) === 0, "rumble(0, 255, 128, 300 ms) is accepted");
  const [type, p] = t.f.log.rumble.at(-1);
  check(type === "dual-rumble" && p.duration === 300 && p.strongMagnitude === 1 && Math.abs(p.weakMagnitude - 128 / 255) < 1e-9, "playEffect('dual-rumble', strong 1.0, weak 0.502, 300 ms)");
  check(t.call("p_hap_rumble", 4, 0, 0, 10) === -3 && t.call("p_hap_rumble", 0, 256, 0, 10) === -3 && t.call("p_hap_rumble", 0, 0, -1, 10) === -3 && t.call("p_hap_rumble", 0, 0, 0, 0) === -3, "pad 4, strong 256, weak -1, 0 ms are DEV_INVALID");
  check(t.call("p_hap_rumble", 1, 10, 10, 10) === -3, "a pad that is not connected is DEV_INVALID");
  const { os } = t; // the host checks the same limits itself: a caller that does not go through the Mojo backend gets the same answer
  const before = t.f.log.vibrate.length;
  rt_bytes(t, 4).set([0x70, 0x17, 0x71, 0x17]); // 6000, 6001
  check(os.env.os_dev_vibrate(t.buf, 1n) === -3 && os.env.os_dev_vibrate(t.buf, 33) === -3 && t.f.log.vibrate.length === before, "called without the Mojo backend, the host also refuses an entry over 5000 and 33 entries");
  check(t.call("p_hap_cancel") === 0 && t.f.log.vibrate.at(-1) === 0 && t.f.log.rumble.at(-1)[0] === "reset", "cancel stops navigator.vibrate and resets the actuator");
}
{
  const t = await boot({ vibrate: false, pad: true });
  check(t.call("p_hap_caps") === 2 && t.call("p_hap_vibrate", 10) === -5 && t.call("p_hap_vibrate", 0) === -5, "iOS Safari (no navigator.vibrate): vibrate is DEV_UNSUPPORTED, also before argument checks");
  check(t.call("p_hap_rumble", 0, 1, 1, 10) === 0, "the gamepad still rumbles");
  const u = await boot({ vibrate: false, pad: false });
  check(u.call("p_hap_avail") === UNSUP && u.call("p_hap_cancel") === -5 && u.call("p_hap_rumble", 0, 1, 1, 10) === -5, "no haptics at all: AVAIL_UNSUPPORTED, every call DEV_UNSUPPORTED");
  const ph = await boot({ pad: false });
  check(ph.call("p_hap_rumble", 0, 1, 1, 10) === -5 && ph.call("p_hap_vibrate", 10) === 0, "a phone without a gamepad: rumble is DEV_UNSUPPORTED, vibrate works");
}
function rt_bytes(t, n) { return t.rt.bytes(t.buf, n); }

// ---- Motion --------------------------------------------------------------------------------------------------------------
console.log("Motion");
{
  const t = await boot();
  check(t.call("p_mot_avail") === GRANTED && t.call("p_mot_caps") === 7, "Android Chrome: granted, accel + gyro + orientation");
  check(t.call("p_mot_read", t.buf) === 0, "not started: read returns 0");
  check(t.call("p_mot_start") === 0 && t.f.win.count("devicemotion") === 1 && t.f.win.count("deviceorientation") === 1, "start attaches both listeners");
  t.f.win.dispatch("devicemotion", { accelerationIncludingGravity: { x: 1, y: 2, z: 9.5 }, rotationRate: { alpha: 30, beta: 10, gamma: 20 } });
  t.f.win.dispatch("deviceorientation", { alpha: 90, beta: 45, gamma: -10 });
  rt_bytes(t, 36).fill(0xAA);
  const seq = t.call("p_mot_read", t.buf);
  const s = t.f32(9);
  check(seq === 1 && s[0] === 1 && s[1] === 2 && s[2] === 9.5, "read returns sequence 1; acceleration (1, 2, 9.5)");
  check(s[3] === 30 && s[4] === 10 && s[5] === 20, "Chrome: rotation rate about (x, y, z) = (alpha 30, beta 10, gamma 20) deg/s");
  check(s[6] === 90 && s[7] === 45 && s[8] === -10, "orientation (alpha, beta, gamma) = (90, 45, -10)");
  rt_bytes(t, 36).fill(0xAA);
  check(t.call("p_mot_read", t.buf) === 0 && rt_bytes(t, 36).every((b) => b === 0xAA), "no new sample: 0 and the buffer is not touched");
  t.f.win.dispatch("devicemotion", { accelerationIncludingGravity: { x: 3, y: 0, z: 0 }, rotationRate: null });
  t.f.win.dispatch("devicemotion", { accelerationIncludingGravity: { x: 4, y: 0, z: 0 }, rotationRate: null });
  check(t.call("p_mot_read", t.buf) === 3 && t.f32(1)[0] === 4, "two samples between reads: the newest, sequence 3");
  t.f.win.dispatch("devicemotion", { accelerationIncludingGravity: { x: 5, y: 0, z: 0 } }); // arrives, never read
  t.call("p_mot_stop");
  check(t.f.win.count("devicemotion") === 0 && t.call("p_mot_read", t.buf) === 0, "stop removes the listeners");
  t.f.win.dispatch("devicemotion", { accelerationIncludingGravity: { x: 6, y: 0, z: 0 } });
  check(t.call("p_mot_start") === 0 && t.call("p_mot_read", t.buf) === 0, "restarting does not return a sample that was unread when it stopped");
}
{
  const t = await boot({ ua: "Mozilla/5.0 (Android 14; Mobile; rv:130.0) Gecko/130.0 Firefox/130.0" });
  t.call("p_mot_start");
  t.f.win.dispatch("devicemotion", { accelerationIncludingGravity: { x: 0, y: 0, z: 0 }, rotationRate: { alpha: 30, beta: 10, gamma: 20 } });
  t.call("p_mot_read", t.buf);
  const s = t.f32(9);
  check(s[3] === 10 && s[4] === 20 && s[5] === 30, "not Chrome (the W3C text): rotation rate about (x, y, z) = (beta 10, gamma 20, alpha 30) deg/s");
}
{
  const t = await boot({ iosMotion: true });
  check(t.call("p_mot_avail") === PROMPT && t.call("p_mot_start") === -6, "iOS: AVAIL_PROMPT; start() before the permission is DEV_NOT_GRANTED");
  check(t.call("p_mot_request", 7) === 0, "request_permission(7) is queued");
  await tick();
  const p = t.pkt("p_mot_poll");
  check(p.kind === KIND_PERM && p.id === 7 && p.status === 0 && p.payload.join() === "2,2", "result: KIND_DEV_PERMISSION, id 7, OK, payload [motion = 2, granted = 2]");
  check(t.call("p_mot_avail") === GRANTED && t.call("p_mot_start") === 0, "start works after the grant");
  const d = await boot({ iosMotion: true, iosAnswer: false });
  d.call("p_mot_request", 8); await tick();
  const q = d.pkt("p_mot_poll");
  check(q.id === 8 && q.status === 2 && q.payload[1] === DENIED && d.call("p_mot_start") === -6, "denied: STATUS_ERROR with AVAIL_DENIED; start is DEV_NOT_GRANTED");
  const n = await boot({ motion: false });
  check(n.call("p_mot_avail") === UNSUP && n.call("p_mot_start") === -5, "no motion API: AVAIL_UNSUPPORTED, start is DEV_UNSUPPORTED");
  const i = await boot({ secure: false });
  check(i.call("p_mot_avail") === UNSUP && i.call("p_mot_start") === -5, "an insecure page (HTTP): AVAIL_UNSUPPORTED");
}

// ---- Screen --------------------------------------------------------------------------------------------------------------
console.log("Screen");
{
  const t = await boot();
  const wait = async (id, op, arg = 0) => { t.call("p_scr_request", id, op, arg); await tick(); return t.pkt("p_scr_poll"); };
  check(t.call("p_scr_caps") === 7, "capabilities: fullscreen, wake lock, orientation lock");
  let p = await wait(1, 1);
  check(p.kind === KIND_SCREEN && p.id === 1 && p.status === 2 && t.call("p_scr_state") === 0, "fullscreen without a tap: the browser rejects it, STATUS_ERROR, state 0");
  p = await wait(2, 3, 2);
  check(p.status === 2 && t.call("p_scr_state") === 0, "orientation lock outside fullscreen is refused");
  const a = await boot({ activation: true });
  const w2 = async (id, op, arg = 0) => { a.call("p_scr_request", id, op, arg); await tick(); return a.pkt("p_scr_poll"); };
  p = await w2(3, 1);
  check(p.id === 3 && p.status === 0 && p.payload.join() === "1,1" && a.call("p_scr_state") === 1, "after a tap: OK, payload [op 1, flags fullscreen]");
  p = await w2(4, 3, 2);
  check(p.status === 0 && a.call("p_scr_state") === 5 && a.f.log.lockOrient.at(-1) === "landscape", "orientation lock while fullscreen: flags 5, locked to 'landscape'");
  p = await w2(5, 5);
  check(p.status === 0 && a.call("p_scr_state") === 7 && a.f.log.wake === 1, "wake lock adds flag 2");
  p = await w2(6, 2);
  check(a.call("p_scr_state") === 2, "leaving fullscreen releases the orientation lock and keeps the wake lock");
  p = await w2(7, 6);
  check(a.call("p_scr_state") === 0, "wake off clears the flag");
  await w2(9, 1);
  await w2(10, 3, 1);
  check(a.call("p_scr_state") === 5, "fullscreen and orientation lock again");
  a.f.doc.fullscreenElement = null; // the user presses Esc: the browser leaves fullscreen without being asked
  check(a.call("p_scr_state") === 0, "the browser leaving fullscreen on its own also ends the orientation lock");
  check(a.call("p_scr_request", 8, 0, 0) === -3 && a.call("p_scr_request", 8, 7, 0) === -3 && a.call("p_scr_request", 8, 3, 0) === -3 && a.call("p_scr_request", 8, 3, 4) === -3, "op 0, op 7, orientation 0 and 4 are DEV_INVALID");
  await tick();
  check(a.pkt("p_scr_poll").n === 0, "the refused requests queued nothing");
  const n = await boot({ wake: false, orient: false });
  check(n.call("p_scr_request", 1, 5, 0) === -5 && n.call("p_scr_request", 1, 3, 1) === -5 && n.call("p_scr_caps") === 1, "no wake lock API, no orientation API: DEV_UNSUPPORTED, capabilities 1");
}

// ---- Pointer lock --------------------------------------------------------------------------------------------------------
console.log("PointerLock");
{
  const t = await boot();
  check(t.call("p_ptr_locked") === 0 && t.call("p_ptr_delta", t.buf) === 0, "unlocked: take_delta returns 0");
  t.call("p_ptr_request", 1, 1); await tick();
  let p = t.pkt("p_ptr_poll");
  check(p.kind === KIND_POINTER && p.id === 1 && p.status === 2 && p.payload[0] === 0, "a lock request without a tap is refused (pointerlockerror): STATUS_ERROR, locked 0");
  const a = await boot({ activation: true });
  a.call("p_ptr_request", 2, 1); await tick();
  p = a.pkt("p_ptr_poll");
  check(p.id === 2 && p.status === 0 && p.payload[0] === 1 && a.call("p_ptr_locked") === 1, "after a tap: locked, payload 1");
  a.f.doc.dispatch("mousemove", { movementX: 3, movementY: -2 });
  a.f.doc.dispatch("mousemove", { movementX: 4, movementY: 1 });
  check(a.call("p_ptr_delta", a.buf) === 1 && a.f32(2).join() === "7,-1", "deltas add up: (3, -2) + (4, 1) = (7, -1)");
  check(a.call("p_ptr_delta", a.buf) === 1 && a.f32(2).join() === "0,0", "and are cleared by the read");
  a.f.doc.dispatch("mousemove", { movementX: 9, movementY: 9 });
  a.f.doc.pointerLockElement = null; a.f.doc.dispatch("pointerlockchange");
  p = a.pkt("p_ptr_poll");
  check(p.id === 0 && p.status === 0 && p.payload[0] === 0 && a.call("p_ptr_locked") === 0, "Esc: an id-0 packet with locked 0");
  a.f.doc.documentElement.requestPointerLock = () => { a.f.doc.pointerLockElement = a.f.doc.documentElement; Promise.resolve().then(() => a.f.doc.dispatch("pointerlockchange")); };
  a.call("p_ptr_request", 3, 1); await tick(); a.pkt("p_ptr_poll");
  check(a.call("p_ptr_delta", a.buf) === 1 && a.f32(2).join() === "0,0", "movement from before the release is not delivered after a new lock");
  a.call("p_ptr_request", 4, 0); await tick();
  p = a.pkt("p_ptr_poll");
  check(p.id === 4 && p.status === 0 && p.payload[0] === 0 && a.call("p_ptr_locked") === 0, "an explicit release answers with its own id");
}

// ---- Camera --------------------------------------------------------------------------------------------------------------
console.log("Camera");
{
  const t = await boot();
  check(t.call("p_cam_avail") === PROMPT, "a browser that has not been asked: AVAIL_PROMPT");
  check(t.call("p_cam_open", 1, 0, 480) === -3 && t.call("p_cam_open", 1, 640, 4097) === -3 && t.f.log.getUserMedia === 0, "a size of 0 or over 4096 is DEV_INVALID without a prompt");
  check(t.call("p_cam_open", 1, 1920, 1080) === 0, "open(1920 x 1080) is queued");
  await tick();
  let p = t.pkt("p_cam_poll");
  check(p.kind === KIND_CAMERA && p.id === 1 && p.status === 0 && p.u32(0) === 1280 && p.u32(4) === 720, "the result is the size the camera gave: 1280 x 720");
  check(t.call("p_cam_size") === 1280 * 65536 + 720 && t.call("p_cam_avail") === GRANTED, "frame size, state granted");
  check(t.call("p_cam_open", 2, 640, 480) === -7, "a second open is DEV_BUSY");
  t.call("p_cam_close");
  check(t.f.cams[0].closed && t.call("p_cam_size") === 0, "close stops the source");
  t.call("p_cam_open", 3, 4, 3); await tick();
  p = t.pkt("p_cam_poll");
  check(p.id === 3 && p.u32(0) === 4 && p.u32(4) === 3, "open after close: a new source, 4 x 3");
  const cam = t.f.cams[1];
  check(t.call("p_cam_frame", t.buf, 48) === 0, "no frame yet: 0");
  cam.seed = 9; cam.seq = 1;
  const small = rt_bytes(t, 48).fill(7);
  check(t.call("p_cam_frame", t.buf, 47) === -1 && small[0] === 7, "a buffer of 47 bytes for a 48-byte frame: -1 and nothing written");
  check(t.call("p_cam_frame", t.buf, 48) === 48, "the frame stayed; a big enough buffer takes it: 48 bytes");
  const px = rt_bytes(t, 48);
  check(px[24] === 11 && px[25] === 19 && px[26] === 3 && px[27] === 255, "pixel (2, 1) is RGBA (11, 19, 3, 255)");
  check(t.call("p_cam_frame", t.buf, 48) === 0, "the same frame is not returned twice");
  cam.seed = 3; cam.seq = 4;
  check(t.call("p_cam_frame", t.buf, 47) === -1 && t.call("p_cam_frame", t.buf, 47) === -1 && t.call("p_cam_skipped") === 0, "two reads with a too small buffer return -1 and count no skipped frames");
  check(t.call("p_cam_frame", t.buf, 48) === 48 && rt_bytes(t, 1)[0] === 3 && t.call("p_cam_skipped") === 2, "three frames between reads: the newest is read, 2 skipped");
  t.call("p_cam_close");
  check(t.call("p_cam_frame", t.buf, 48) === 0 && t.call("p_cam_size") === 0, "a closed camera reads 0");
  const d = await boot({ userSays: false });
  d.call("p_cam_open", 5, 640, 480); await tick();
  p = d.pkt("p_cam_poll");
  check(p.id === 5 && p.status === 2 && p.payload[0] === DENIED && d.call("p_cam_size") === 0, "the user says no: STATUS_ERROR with AVAIL_DENIED, camera stays closed");
  check(d.call("p_cam_open", 6, 640, 480) === -6 && d.pkt("p_cam_poll").n === 0, "opening after a denial is DEV_NOT_GRANTED, without a packet");
  const n = await boot({ media: false });
  check(n.call("p_cam_avail") === UNSUP && n.call("p_cam_open", 1, 640, 480) === -5, "no getUserMedia: DEV_UNSUPPORTED");
  check(n.call("p_cam_open", 1, 0, 480) === -5 && d.call("p_cam_open", 1, 0, 480) === -6, "unsupported and denied are reported before a bad size");
  const r = await boot();
  r.call("p_cam_request", 11); await tick();
  p = r.pkt("p_cam_poll");
  check(p.kind === KIND_PERM && p.id === 11 && p.status === 0 && p.payload[0] === 5 && r.f.log.getUserMedia === 1, "request_permission asks the browser once and answers [camera = 5, granted]");
  check(r.call("p_cam_avail") === GRANTED, "and the state is granted");
}

// ---- Microphone ----------------------------------------------------------------------------------------------------------
console.log("Microphone");
{
  const t = await boot({ micRate: 48000 });
  check(t.call("p_mic_open", 1, 7999) === -3 && t.call("p_mic_open", 1, 192001) === -3 && t.f.log.getUserMedia === 0, "7999 Hz and 192001 Hz are DEV_INVALID, without a prompt");
  check(t.call("p_mic_open", 1, 44100) === 0, "open(44100)");
  await tick();
  let p = t.pkt("p_mic_poll");
  check(p.kind === KIND_MIC && p.id === 1 && p.status === 0 && p.u32(0) === 48000 && t.call("p_mic_rate") === 48000, "the device runs at 48000 Hz whatever was asked: the result says so");
  check(t.call("p_mic_open", 2, 44100) === -7, "a second open is DEV_BUSY");
  const m = t.f.mics[0];
  m.push(Float32Array.from({ length: 10 }, (_, i) => i / 10));
  check(t.call("p_mic_read", t.buf, 4) === 4 && t.f32(4).join() === Array.from({ length: 4 }, (_, i) => Math.fround(i / 10)).join(), "read(4) returns the 4 oldest samples");
  check(t.call("p_mic_read", t.buf, 16) === 6 && t.f32(6)[0] === Math.fround(0.4) && t.f32(6)[5] === Math.fround(0.9), "the rest comes next, in order: 6 samples");
  check(t.call("p_mic_read", t.buf, 16) === 0 && t.call("p_mic_read", t.buf, 0) === 0, "an empty ring reads 0");
  m.push(new Float32Array(48000).fill(0.25));
  m.push(Float32Array.from({ length: 100 }, (_, i) => i + 1));
  check(t.call("p_mic_overruns") === 100, "100 samples over one second of ring: 100 oldest discarded and counted");
  check(t.call("p_mic_read", t.buf, 48000) === 48000 && t.f32(1, 4 * 47999)[0] === 100 && t.f32(1, 4 * 47900)[0] === 1 && t.f32(1)[0] === 0.25, "what remains is the newest second: the last sample is 100.0");
  t.call("p_mic_close");
  check(m.closed && t.call("p_mic_rate") === 0 && t.call("p_mic_read", t.buf, 4) === 0, "closed: nothing is read");
  const d = await boot({ userSays: false });
  d.call("p_mic_open", 3, 16000); await tick();
  p = d.pkt("p_mic_poll");
  check(p.id === 3 && p.status === 2 && p.payload[0] === DENIED && d.call("p_mic_open", 4, 16000) === -6, "denied: STATUS_ERROR, and later opens are DEV_NOT_GRANTED");
  const n = await boot({ media: false });
  check(n.call("p_mic_open", 1, 16000) === -5 && n.call("p_mic_avail") === UNSUP, "no microphone API: DEV_UNSUPPORTED");
  check(n.call("p_mic_open", 1, 1) === -5 && d.call("p_mic_open", 1, 1) === -6, "unsupported and denied are reported before a bad rate");
}

// ---- Router --------------------------------------------------------------------------------------------------------------
console.log("Shared os_poll reader");
{
  const t = await boot({ iosMotion: true, activation: true });
  // four results in flight together; each seam must get exactly its own whichever polls first
  t.call("p_mot_request", 21);
  t.call("p_cam_open", 22, 8, 8);
  t.call("p_scr_request", 23, 5, 0);
  t.call("p_ptr_request", 24, 1);
  await tick();
  const order = [["p_ptr_poll", 24, KIND_POINTER], ["p_scr_poll", 23, KIND_SCREEN], ["p_cam_poll", 22, KIND_CAMERA], ["p_mot_poll", 21, KIND_PERM]];
  const got = order.map(([f]) => t.pkt(f));
  check(got.every((g, i) => g.id === order[i][1] && g.kind === order[i][2]), "pointer, screen, camera and motion results, taken in reverse order, each arrive once with their own id and kind");
  check(order.every(([f]) => t.pkt(f).n === 0) && t.call("p_foreign") === 0, "nothing is left over and nothing was dropped as foreign");
}

console.log(`device: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
