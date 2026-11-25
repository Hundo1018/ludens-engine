#!/usr/bin/env python3
"""The device seams in a real Chrome (ludens-engine #135, docs/platform.md "Device seams: verified"): the web backends compiled
into build/device_probe.wasm run over the real `os_dev_*` imports and Chrome's own navigator. Chrome supplies a synthetic camera and
microphone (--use-fake-device-for-media-stream), a permission prompt that answers yes, sensor overrides over DevTools, and a user
activation from `Runtime.evaluate`. No hardware: a real phone's motor, lens and gyroscope are not covered, and the camera copy time
is that of Chrome's synthetic camera on this machine.

    pixi run -e wasm device-web                # checks, and the camera copy time per frame
    CHROME=/path/to/chrome pixi run -e wasm device-web"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "build/device_web"
PORT = 8142

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>device probe</title>
<script type="module">
import { instantiate } from "./host.mjs";
import { createOsImports } from "./os_host.mjs";
try {
  const rt = await instantiate(await (await fetch("./device_probe.wasm")).arrayBuffer(), { libs: [(r) => createOsImports(r)] });
  const h = rt.call("p_new");
  const buf = rt.alloc(1 << 22);
  const call = (n, ...a) => Number(rt.call(n, h, ...a));
  const f32 = (n, at = 0) => { const b = rt.bytes(buf + BigInt(at), n * 4); const v = new DataView(b.buffer, b.byteOffset, n * 4); return Array.from({ length: n }, (_, i) => v.getFloat32(4 * i, true)); };
  const pkt = (poller, cap = 256) => {
    const n = call(poller, buf, cap);
    if (n <= 0) return null;
    const b = rt.bytes(buf, n), v = new DataView(b.buffer, b.byteOffset, n);
    const u32 = []; for (let i = 6; i + 4 <= n; i += 4) u32.push(v.getUint32(i, true));
    return { n, kind: b[0], id: v.getUint32(1, true), status: b[5], payload: Array.from(b.slice(6)), u32 };
  };
  // The three steps of the camera copy, each timed alone over the same video, canvas and wasm buffer (only the timed calls are inside the loop).
  const breakdown = async (w, h, n) => {
    const stream = await navigator.mediaDevices.getUserMedia({ video: { width: { ideal: w }, height: { ideal: h } } });
    const video = document.createElement("video");
    video.muted = true; video.srcObject = stream; await video.play();
    const cw = Math.min(w, video.videoWidth), ch = Math.min(h, video.videoHeight);
    const canvas = document.createElement("canvas"); canvas.width = cw; canvas.height = ch;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    const dst = rt.bytes(buf, cw * ch * 4);
    const t = { draw: [], read: [], set: [] };
    for (let i = 0; i < n; i++) {
      await new Promise((r) => video.requestVideoFrameCallback(r));
      const a = performance.now(); ctx.drawImage(video, 0, 0, cw, ch);
      const b = performance.now(); const img = ctx.getImageData(0, 0, cw, ch);
      const c = performance.now(); dst.set(img.data);
      const d = performance.now();
      t.draw.push(b - a); t.read.push(c - b); t.set.push(d - c);
    }
    stream.getTracks().forEach((x) => x.stop());
    const med = (v) => v.slice().sort((x, y) => x - y)[v.length >> 1];
    return { width: cw, height: ch, n, drawMs: med(t.draw), getImageDataMs: med(t.read), setIntoWasmMs: med(t.set) };
  };
  window.dev = { rt, buf, call, f32, pkt, breakdown };
} catch (e) { window.devError = String(e && e.stack || e); }
</script>
"""


def main() -> int:
    chrome = os.environ.get("CHROME") or shutil.which("google-chrome") or shutil.which("chromium")
    if not chrome:
        sys.exit("device_web_check: no Chrome found (set CHROME)")
    sys.path.insert(0, str(ROOT / "scripts"))
    import test_device

    rc = test_device.build()
    if rc:
        return rc
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    shutil.copy(ludens_wasm_rt.HOST_MJS, OUT / "host.mjs")
    for f in ("os_host.mjs", "device_host.mjs"):
        shutil.copy(ROOT / "shell/web" / f, OUT / f)
    shutil.copy(ROOT / "build/device_probe.wasm", OUT / "device_probe.wasm")
    (OUT / "index.html").write_text(PAGE)
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1", "--directory", str(OUT)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        time.sleep(1)
        r = subprocess.run(["node", "scripts/device_web.mjs", chrome, f"http://127.0.0.1:{PORT}/index.html"], cwd=ROOT, capture_output=True, text=True, check=False)
    finally:
        server.kill()
    if r.returncode:
        sys.exit(r.stdout + r.stderr)
    result = json.loads(r.stdout.strip().splitlines()[-1])
    failed = 0
    for label, ok, detail in result["checks"]:
        failed += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] {label}" + ("" if ok or not detail else f"  ({detail})"))
    print(f"device_web: {len(result['checks']) - failed} / {len(result['checks'])} checks, Chrome: {subprocess.run([chrome, '--version'], capture_output=True, text=True, check=False).stdout.strip()}")
    print("numbers:", json.dumps(result["numbers"], indent=1))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
