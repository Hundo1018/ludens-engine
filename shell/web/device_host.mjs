// os_dev_* imports (ludens-engine #135): haptics, motion sensors, screen, pointer lock, camera, microphone.
// The Mojo side is platform/{haptics,motion,screen,pointer_lock,camera,microphone}.mojo; the web backend over these imports is
// app/os_device.mojo. Return codes are the ones in platform/device.mojo: 0 ok / queued, -3 invalid argument, -5 unsupported,
// -6 not granted, -7 busy. Results of asynchronous requests are packets [kind u8][id u32 LE][status u8][payload] pushed to the
// os_poll queue (kinds 32 to 36). Nothing calls into wasm.
//
//   os_dev_state(dev) -> 0 unsupported, 1 needs a request, 2 granted, 3 denied        (dev: 1 haptics 2 motion 3 screen 4 pointer lock 5 camera 6 mic)
//   os_dev_caps(dev) -> bit set, see capsOf() below
//   os_dev_permission_request(dev, id) -> 0 queued                                   result: kind 32 [dev][state]
//   os_dev_vibrate(ptr, count) -> u16 LE on / off milliseconds, count 0 cancels
//   os_dev_rumble(pad, strong, weak, ms)
//   os_dev_motion_start() / os_dev_motion_stop() / os_dev_motion_read(ptr) -> sequence, 0 none new; writes 9 f32 (36 bytes)
//   os_dev_screen_request(id, op, arg) / os_dev_screen_state()                        result: kind 33 [op][flags]
//   os_dev_pointer_request(id, on) / os_dev_pointer_delta(ptr) -> 1 locked (2 f32 written), 0 not    result: kind 34 [locked]
//   os_dev_camera_open(id, w, h) / os_dev_camera_close() / os_dev_camera_frame(ptr, cap) -> bytes, 0 none new, -1 cap too small    result: kind 35
//   os_dev_camera_skipped() -> frames made and not read; os_dev_pointer_locked() -> 1 / 0
//   os_dev_camera_size() -> width * 65536 + height, 0 closed
//   os_dev_mic_open(id, rate) / os_dev_mic_close() / os_dev_mic_read(ptr, max_samples) -> samples / os_dev_mic_overruns() / os_dev_mic_rate()   result: kind 36
//
// Only what a browser can ask for is here. A privilege the page has not been given (camera, microphone, motion on iOS) is a
// request the user answers; the page never reads a device it has no permission for.
export const KIND_PERMISSION = 32, KIND_SCREEN = 33, KIND_POINTER = 34, KIND_CAMERA = 35, KIND_MIC = 36;
export const DEV = { haptics: 1, motion: 2, screen: 3, pointer: 4, camera: 5, mic: 6 };
const UNSUPPORTED = 0, PROMPT = 1, GRANTED = 2, DENIED = 3;
const OK = 0, INVALID = -3, NO_SUPPORT = -5, NOT_GRANTED = -6, BUSY = -7;
const MAX_VIBRATE_MS = 5000, MAX_PATTERN = 32;
const MIC_RING_SECONDS = 1;

function packet(kind, id, st, payload) {
  const out = new Uint8Array(6 + payload.length);
  out[0] = kind;
  new DataView(out.buffer).setUint32(1, id >>> 0, true);
  out[5] = st;
  out.set(payload, 6);
  return out;
}
const u32 = (...v) => { const b = new Uint8Array(4 * v.length); v.forEach((x, i) => new DataView(b.buffer).setUint32(4 * i, x >>> 0, true)); return b; };

/** What the page can use, read from the real browser objects. Tests pass fakes with the same shape. */
export function browserDevice(g = globalThis) {
  return {
    navigator: g.navigator, document: g.document, screen: g.screen, window: g,
    isSecure: g.isSecureContext !== false,
    openCamera: (w, h) => openBrowserCamera(g, w, h),
    openMic: (rate) => openBrowserMic(g, rate),
  };
}

export function createDeviceImports(rt, push, dev = browserDevice()) {
  const nav = dev.navigator, doc = dev.document, win = dev.window;
  const status = { vibrates: 0, rumbles: 0, motionSamples: 0, cameraFrames: 0, cameraBytes: 0, micSamples: 0 };
  const perm = { camera: PROMPT, mic: PROMPT, motion: PROMPT };
  // The Permissions API tells us a decision the user already made (a camera allowed last visit).
  const track = async (name, key) => {
    try {
      const r = await nav.permissions.query({ name });
      const map = (s) => (s === "granted" ? GRANTED : s === "denied" ? DENIED : PROMPT);
      perm[key] = map(r.state);
      r.onchange = () => { perm[key] = map(r.state); };
    } catch { /* the browser does not know this permission name: stay at PROMPT */ }
  };
  if (nav?.permissions?.query) { track("camera", "camera"); track("microphone", "mic"); }

  const hasVibrate = typeof nav?.vibrate === "function";
  const pads = () => { try { return nav.getGamepads?.() ?? []; } catch { return []; } };
  const rumbleOf = (g) => g?.vibrationActuator ?? null;
  const hasRumble = () => pads().some((g) => g && rumbleOf(g));

  // ---- motion -------------------------------------------------------------------------------------------------------------
  const needsMotionPrompt = typeof win?.DeviceMotionEvent?.requestPermission === "function";
  const motionExists = !!win && ("DeviceMotionEvent" in win || "DeviceOrientationEvent" in win) && dev.isSecure;
  if (motionExists && !needsMotionPrompt) perm.motion = GRANTED;
  const chromium = /Chrome\//.test(nav?.userAgent ?? "");
  const motion = { running: false, seq: 0, readSeq: 0, s: new Float32Array(9) };
  const onMotion = (e) => {
    const a = e.accelerationIncludingGravity, r = e.rotationRate;
    if (a) { motion.s[0] = a.x ?? 0; motion.s[1] = a.y ?? 0; motion.s[2] = a.z ?? 0; }
    if (r) { // rotation rate about the device's x, y, z (deg/s). The W3C text puts alpha about z, beta about x, gamma about y, but Chrome
      // 158 reports alpha = x, beta = y, gamma = z (measured with DevTools sensor overrides: scripts/device_web.mjs). Other browsers follow the text; that is unmeasured.
      const [x, y, z] = chromium ? [r.alpha, r.beta, r.gamma] : [r.beta, r.gamma, r.alpha];
      motion.s[3] = x ?? 0; motion.s[4] = y ?? 0; motion.s[5] = z ?? 0;
    }
    motion.seq++; status.motionSamples++;
  };
  const onOrient = (e) => { motion.s[6] = e.alpha ?? 0; motion.s[7] = e.beta ?? 0; motion.s[8] = e.gamma ?? 0; };

  // ---- screen -------------------------------------------------------------------------------------------------------------
  let wake = null;
  let orientLocked = false;
  const screenFlags = () => {
    if (!doc?.fullscreenElement) orientLocked = false; // leaving fullscreen releases the lock
    return (doc?.fullscreenElement ? 1 : 0) | (wake && !wake.released ? 2 : 0) | (orientLocked ? 4 : 0);
  };
  const screenCaps = () => (doc?.documentElement?.requestFullscreen ? 1 : 0) | (nav?.wakeLock?.request ? 2 : 0) | (dev.screen?.orientation?.lock ? 4 : 0);
  const orientName = ["", "portrait", "landscape", "any"];

  // ---- pointer lock -------------------------------------------------------------------------------------------------------
  const ptr = { dx: 0, dy: 0, wired: false };
  const wirePointer = () => {
    if (ptr.wired || !doc) return;
    ptr.wired = true;
    doc.addEventListener("mousemove", (e) => { if (doc.pointerLockElement) { ptr.dx += e.movementX; ptr.dy += e.movementY; } });
    doc.addEventListener("pointerlockchange", () => {
      if (!doc.pointerLockElement) { ptr.dx = 0; ptr.dy = 0; ptr.pending ? ptr.pending(false) : push(packet(KIND_POINTER, 0, 0, Uint8Array.of(0))); ptr.pending = null; }
      else if (ptr.pending) { ptr.pending(true); ptr.pending = null; }
    });
    doc.addEventListener("pointerlockerror", () => { if (ptr.pending) { ptr.pending(false, true); ptr.pending = null; } });
  };

  // ---- camera and microphone ----------------------------------------------------------------------------------------------
  let cam = null, camBusy = false, camSeq = 0, camSkipped = 0;
  let mic = null, micBusy = false;
  const denial = (e, key) => { if (e?.name === "NotAllowedError" || e?.name === "SecurityError") perm[key] = DENIED; else if (e?.name === "NotFoundError") perm[key] = UNSUPPORTED; };

  const caps = {
    [DEV.haptics]: () => (hasVibrate ? 1 : 0) | (hasRumble() ? 2 : 0),
    [DEV.motion]: () => (motionExists ? 7 : 0),
    [DEV.screen]: screenCaps,
    [DEV.pointer]: () => (doc?.documentElement?.requestPointerLock ? 1 : 0),
    [DEV.camera]: () => (nav?.mediaDevices?.getUserMedia ? 1 : 0),
    [DEV.mic]: () => (nav?.mediaDevices?.getUserMedia ? 1 : 0),
  };
  const stateOf = (d) => {
    if (!caps[d] || caps[d]() === 0) return UNSUPPORTED;
    if (d === DEV.motion) return perm.motion;
    if (d === DEV.camera) return perm.camera;
    if (d === DEV.mic) return perm.mic;
    return GRANTED;
  };

  const env = {
    os_dev_state: (d) => stateOf(Number(d)),
    os_dev_caps: (d) => (caps[Number(d)] ? caps[Number(d)]() : 0),
    os_dev_permission_request(d, id) {
      d = Number(d); id = Number(id);
      const done = () => { const s = stateOf(d); push(packet(KIND_PERMISSION, id, s === GRANTED ? 0 : 2, Uint8Array.of(d, s))); };
      if (!caps[d]) return INVALID;
      if (stateOf(d) === UNSUPPORTED) return NO_SUPPORT;
      if (d === DEV.motion && needsMotionPrompt && perm.motion === PROMPT) {
        Promise.all([win.DeviceMotionEvent.requestPermission(), win.DeviceOrientationEvent?.requestPermission?.() ?? "granted"])
          .then((r) => { perm.motion = r.every((x) => x === "granted") ? GRANTED : DENIED; }, () => { perm.motion = DENIED; }).then(done);
      } else if ((d === DEV.camera || d === DEV.mic) && perm[d === DEV.camera ? "camera" : "mic"] === PROMPT) {
        const key = d === DEV.camera ? "camera" : "mic";
        nav.mediaDevices.getUserMedia(d === DEV.camera ? { video: true } : { audio: true })
          .then((s) => { s.getTracks().forEach((t) => t.stop()); perm[key] = GRANTED; }, (e) => denial(e, key)).then(done);
      } else Promise.resolve().then(done);
      return OK;
    },

    os_dev_vibrate(p, count) {
      count = Number(count);
      if (count === 0) { // cancel: stop the vibration motor and every gamepad actuator
        if (!hasVibrate && !hasRumble()) return NO_SUPPORT;
        if (hasVibrate) nav.vibrate(0);
        for (const g of pads()) rumbleOf(g)?.reset?.()?.catch?.(() => {});
        return OK;
      }
      if (!hasVibrate) return NO_SUPPORT;
      if (count < 0 || count > MAX_PATTERN) return INVALID;
      const b = rt.bytes(p, count * 2), pat = [];
      for (let i = 0; i < count; i++) { const v = b[2 * i] | (b[2 * i + 1] << 8); if (v > MAX_VIBRATE_MS) return INVALID; pat.push(v); }
      status.vibrates++;
      return nav.vibrate(pat.length === 1 ? pat[0] : pat) ? OK : NOT_GRANTED;
    },
    os_dev_rumble(pad, strong, weak, ms) {
      pad = Number(pad); strong = Number(strong); weak = Number(weak); ms = Number(ms);
      const act = rumbleOf(pads()[pad]);
      if (!act) return hasRumble() ? INVALID : NO_SUPPORT;
      if (pad < 0 || pad > 3 || strong < 0 || strong > 255 || weak < 0 || weak > 255 || ms < 1 || ms > MAX_VIBRATE_MS) return INVALID;
      status.rumbles++;
      act.playEffect?.("dual-rumble", { startDelay: 0, duration: ms, strongMagnitude: strong / 255, weakMagnitude: weak / 255 })?.catch?.(() => {});
      return OK;
    },

    os_dev_motion_start() {
      if (!motionExists) return NO_SUPPORT;
      if (perm.motion !== GRANTED) return NOT_GRANTED;
      if (!motion.running) { win.addEventListener("devicemotion", onMotion); win.addEventListener("deviceorientation", onOrient); }
      motion.running = true; motion.readSeq = motion.seq;
      return OK;
    },
    os_dev_motion_stop() {
      if (motion.running) { win.removeEventListener("devicemotion", onMotion); win.removeEventListener("deviceorientation", onOrient); }
      motion.running = false;
      return 0;
    },
    os_dev_motion_read(p) {
      if (!motion.running || motion.seq === motion.readSeq) return 0;
      const b = rt.bytes(p, 36);
      for (let i = 0; i < 9; i++) new DataView(b.buffer, b.byteOffset, 36).setFloat32(4 * i, motion.s[i], true);
      motion.readSeq = motion.seq;
      return motion.seq;
    },

    os_dev_screen_request(id, op, arg) {
      id = Number(id); op = Number(op); arg = Number(arg);
      const need = [0, 1, 1, 4, 4, 2, 2][op] ?? 0;
      if (!need || (op === 3 && (arg < 1 || arg > 3))) return INVALID;
      if (!(screenCaps() & need)) return NO_SUPPORT;
      const finish = (ok) => push(packet(KIND_SCREEN, id, ok ? 0 : 2, Uint8Array.of(op, screenFlags())));
      const run = async () => {
        if (op === 1) await doc.documentElement.requestFullscreen();
        else if (op === 2) { orientLocked = false; if (doc.fullscreenElement) await doc.exitFullscreen(); }
        else if (op === 3) { await dev.screen.orientation.lock(orientName[arg]); orientLocked = true; }
        else if (op === 4) { dev.screen.orientation.unlock(); orientLocked = false; }
        else if (op === 5) { wake = await nav.wakeLock.request("screen"); wake.addEventListener?.("release", () => { wake.released = true; }); }
        else if (wake) { await wake.release(); wake = null; }
      };
      run().then(() => finish(true), () => finish(false));
      return OK;
    },
    os_dev_screen_state: () => screenFlags(),

    os_dev_pointer_request(id, on) {
      id = Number(id);
      if (!doc?.documentElement?.requestPointerLock) return NO_SUPPORT;
      wirePointer();
      const answer = (locked) => push(packet(KIND_POINTER, id, 0, Uint8Array.of(locked ? 1 : 0)));
      if (Number(on)) {
        if (doc.pointerLockElement) { answer(true); return OK; }
        ptr.pending = (locked, err) => push(packet(KIND_POINTER, id, locked ? 0 : 2, Uint8Array.of(locked ? 1 : 0)));
        try { const r = (doc.querySelector?.("canvas") ?? doc.documentElement).requestPointerLock(); r?.catch?.(() => { ptr.pending?.(false, true); ptr.pending = null; }); }
        catch { ptr.pending(false, true); ptr.pending = null; }
      } else if (doc.pointerLockElement) { ptr.pending = () => answer(false); doc.exitPointerLock(); } else answer(false);
      return OK;
    },
    os_dev_pointer_locked: () => (doc?.pointerLockElement ? 1 : 0),
    os_dev_pointer_delta(p) {
      if (!doc?.pointerLockElement) return 0;
      const b = rt.bytes(p, 8), v = new DataView(b.buffer, b.byteOffset, 8);
      v.setFloat32(0, ptr.dx, true); v.setFloat32(4, ptr.dy, true);
      ptr.dx = 0; ptr.dy = 0;
      return 1;
    },

    os_dev_camera_open(id, w, h) {
      id = Number(id); w = Number(w); h = Number(h);
      if (!nav?.mediaDevices?.getUserMedia) return NO_SUPPORT;
      if (perm.camera === DENIED) return NOT_GRANTED;
      if (perm.camera === UNSUPPORTED) return NO_SUPPORT;
      if (w < 1 || w > 4096 || h < 1 || h > 4096) return INVALID;
      if (cam || camBusy) return BUSY;
      camBusy = true;
      dev.openCamera(w, h).then(
        (c) => { cam = c; camBusy = false; camSeq = 0; camSkipped = 0; perm.camera = GRANTED; push(packet(KIND_CAMERA, id, 0, u32(c.width, c.height))); },
        (e) => { camBusy = false; denial(e, "camera"); push(packet(KIND_CAMERA, id, 2, Uint8Array.of(stateOf(DEV.camera)))); },
      );
      return OK;
    },
    os_dev_camera_close() { cam?.close(); cam = null; return 0; },
    os_dev_camera_skipped: () => camSkipped,
    os_dev_camera_size: () => (cam ? cam.width * 65536 + cam.height : 0),
    os_dev_camera_frame(p, cap) {
      if (!cam) return 0n;
      const seq = cam.frameSeq();
      if (seq === camSeq) return 0n;
      const need = cam.width * cam.height * 4;
      if (need > Number(cap)) return -1n; // the frame stays; nothing is counted until it is taken
      if (camSeq !== 0) camSkipped += seq - camSeq - 1; // frames the camera made that the game never read
      cam.copyTo(rt.bytes(p, need));
      camSeq = seq; status.cameraFrames++; status.cameraBytes += need;
      return BigInt(need);
    },

    os_dev_mic_open(id, rate) {
      id = Number(id); rate = Number(rate);
      if (!nav?.mediaDevices?.getUserMedia) return NO_SUPPORT;
      if (perm.mic === DENIED) return NOT_GRANTED;
      if (perm.mic === UNSUPPORTED) return NO_SUPPORT;
      if (rate < 8000 || rate > 192000) return INVALID;
      if (mic || micBusy) return BUSY;
      micBusy = true;
      dev.openMic(rate).then(
        (m) => { mic = m; micBusy = false; perm.mic = GRANTED; push(packet(KIND_MIC, id, 0, u32(m.rate))); },
        (e) => { micBusy = false; denial(e, "mic"); push(packet(KIND_MIC, id, 2, Uint8Array.of(stateOf(DEV.mic)))); },
      );
      return OK;
    },
    os_dev_mic_close() { mic?.close(); mic = null; return 0; },
    os_dev_mic_rate: () => (mic ? mic.rate : 0),
    os_dev_mic_overruns: () => BigInt(mic ? mic.overruns() : 0),
    os_dev_mic_read(p, max) {
      if (!mic || Number(max) <= 0) return 0;
      const b = rt.bytes(p, Number(max) * 4);
      const aligned = b.byteOffset % 4 === 0; // a Float32Array view needs a 4-byte aligned start
      const dst = aligned ? new Float32Array(b.buffer, b.byteOffset, Number(max)) : new Float32Array(Number(max));
      const n = mic.read(dst);
      if (!aligned) b.set(new Uint8Array(dst.buffer, 0, n * 4));
      status.micSamples += n;
      return n;
    },
  };
  return { env, status };
}

/** A ring of f32 samples that drops the oldest and counts them, shared by the real and the fake microphone source. */
export function sampleRing(rate) {
  const cap = rate * MIC_RING_SECONDS, data = new Float32Array(cap);
  let start = 0, len = 0, over = 0;
  return {
    push(src) {
      for (let i = 0; i < src.length; i++) {
        if (len === cap) { start = (start + 1) % cap; len--; over++; }
        data[(start + len) % cap] = src[i]; len++;
      }
    },
    read(dst) { const n = Math.min(dst.length, len); for (let i = 0; i < n; i++) dst[i] = data[(start + i) % cap]; start = (start + n) % cap; len -= n; return n; },
    overruns: () => over,
  };
}

async function openBrowserCamera(g, w, h) {
  const stream = await g.navigator.mediaDevices.getUserMedia({ video: { width: { ideal: w }, height: { ideal: h } } });
  const video = g.document.createElement("video");
  video.muted = true; video.playsInline = true; video.srcObject = stream;
  await video.play();
  const width = Math.min(w, video.videoWidth || w), height = Math.min(h, video.videoHeight || h);
  const canvas = g.document.createElement("canvas");
  canvas.width = width; canvas.height = height;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  let seq = 0, stopped = false;
  const tick = () => { seq++; if (!stopped) video.requestVideoFrameCallback(tick); };
  video.requestVideoFrameCallback(tick);
  return {
    width, height,
    frameSeq: () => seq,
    copyTo(dst) { ctx.drawImage(video, 0, 0, width, height); dst.set(ctx.getImageData(0, 0, width, height).data); },
    close() { stopped = true; stream.getTracks().forEach((t) => t.stop()); video.srcObject = null; },
  };
}

const WORKLET = `class Cap extends AudioWorkletProcessor { process(i) { const c = i[0] && i[0][0]; if (c) this.port.postMessage(c.slice()); return true; } } registerProcessor("ludens-mic", Cap);`;
async function openBrowserMic(g, rate) {
  const stream = await g.navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: false, noiseSuppression: false, autoGainControl: false } });
  const ctx = new g.AudioContext({ sampleRate: rate });
  const url = g.URL.createObjectURL(new g.Blob([WORKLET], { type: "text/javascript" }));
  await ctx.audioWorklet.addModule(url);
  g.URL.revokeObjectURL(url);
  const node = new g.AudioWorkletNode(ctx, "ludens-mic", { numberOfInputs: 1, numberOfOutputs: 0 });
  const ring = sampleRing(ctx.sampleRate);
  node.port.onmessage = (e) => ring.push(e.data);
  ctx.createMediaStreamSource(stream).connect(node);
  await ctx.resume();
  return { rate: ctx.sampleRate, read: ring.read, overruns: ring.overruns, close() { stream.getTracks().forEach((t) => t.stop()); ctx.close(); } };
}
