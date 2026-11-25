#!/usr/bin/env python3
"""Mutation check for the device seams (issue #135): apply one source change at a time and require that the covering test fails.

    pixi run -e wasm mutation-device          # all mutations
    pixi run -e wasm mutation-device H1 J3    # chosen ones

Each mutation breaks one rule of the contract in docs/platform.md ("Device seams"). Tests: `platform_device` is
tests/platform_device.mojo (the in-memory backends), `device` is scripts/test_device.py (the web backends and shell/web/device_host.mjs
against fake browser objects). The covering test must exit non-zero with a `[FAIL]` line; a mutation that leaves it green, or that
only crashes it, is reported and the script exits 1. The sources are restored afterwards, also when the script is interrupted.
Not part of CI: it builds a test once per mutation."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HAP, MOT, SCR, PTR = "platform/haptics.mojo", "platform/motion.mojo", "platform/screen.mojo", "platform/pointer_lock.mojo"
CAM, MIC, DEV = "platform/camera.mojo", "platform/microphone.mojo", "platform/device.mojo"
JS, ROUTER = "shell/web/device_host.mjs", "app/os_router.mojo"
P, W = "platform_device", "device"

# id, file, text to replace (must occur once), replacement, test, rule it breaks
MUTATIONS = [
    ("H1", HAP, "        if ms < 1 or ms > MAX_VIBRATE_MS:\n            return DEV_INVALID\n        self.pattern", "        if ms < 1:\n            return DEV_INVALID\n        self.pattern", P, "vibrate accepts a duration over 5000 ms"),
    ("H2", HAP, "        if (Int(p[2 * i]) | (Int(p[2 * i + 1]) << 8)) > MAX_VIBRATE_MS:", "        if (Int(p[2 * i]) | (Int(p[2 * i + 1]) << 8)) > 65535:", P, "a pattern entry over 5000 ms is accepted"),
    ("H3", HAP, "pad < 0 or pad >= MAX_PADS", "pad < 0 or pad > MAX_PADS", P, "rumble accepts pad 4"),
    ("H4", HAP, "        if self.caps & HAP_VIBRATE == 0:\n            return DEV_UNSUPPORTED\n        if ms < 1", "        if ms < 1", P, "vibrate is not refused where navigator.vibrate is missing"),
    ("A1", MOT, "        self._read_seq = self._seq\n        return self._seq", "        return self._seq", P, "a sample can be read twice"),
    ("A2", MOT, "        if self.gate.state != AVAIL_GRANTED:\n            return DEV_NOT_GRANTED", "        if False:\n            return DEV_NOT_GRANTED", P, "start works before the permission is granted"),
    ("A3", MOT, "        self.running = True\n        self._read_seq = self._seq", "        self.running = True", P, "a restart returns the sample from before the stop"),
    ("A4", DEV, "            self.state = AVAIL_GRANTED if self.answer else AVAIL_DENIED", "            self.state = AVAIL_GRANTED", P, "a refused prompt counts as granted"),
    ("S1", SCR, "            ok = (self._flags & SCREEN_F_FULLSCREEN) != 0", "            ok = True", P, "orientation lock works outside fullscreen"),
    ("S2", SCR, "self._flags &= ~(SCREEN_F_FULLSCREEN | SCREEN_F_ORIENT)", "self._flags &= ~SCREEN_F_FULLSCREEN", P, "leaving fullscreen keeps the orientation lock"),
    ("S3", SCR, "            ok = self._activation\n            self._activation = False", "            ok = self._activation", P, "one tap allows fullscreen for ever"),
    ("L1", PTR, "            self._locked = False\n            self._dx = 0\n            self._dy = 0\n            var payload", "            self._locked = False\n            var payload", P, "movement before an Esc is delivered after the next lock"),
    ("L2", PTR, "        self._dx = 0\n        self._dy = 0\n        return 1", "        return 1", P, "a delta is not cleared when read"),
    ("C1", CAM, "            self._w = min(width, self.max_width)", "            self._w = width", P, "the camera reports the asked size, not the size it gave"),
    ("C2", CAM, "        if n > cap:\n            return -1", "        if False:\n            return -1", P, "a frame is written past a too small buffer"),
    ("C3", CAM, "        if self._fresh:\n            self._skipped += 1", "        if False:\n            self._skipped += 1", P, "lost frames are not counted"),
    ("C4", CAM, "        if self.gate.state == AVAIL_DENIED:\n            return DEV_NOT_GRANTED", "        if False:\n            return DEV_NOT_GRANTED", P, "open after a denial asks again"),
    ("C5", CAM, "        if width < 1 or width > MAX_CAMERA_DIM or height < 1 or height > MAX_CAMERA_DIM:", "        if False:", P, "a camera size of 0 or over 4096 is accepted"),
    ("I1", MIC, "            self._overruns += extra", "            pass", P, "discarded samples are not counted"),
    ("I2", MIC, "            for i in range(extra, len(self._ring)):", "            for i in range(0, len(self._ring) - extra):", P, "the ring keeps the oldest samples, not the newest"),
    ("I3", MIC, "            self._rate = self.device_rate if self.device_rate > 0 else sample_rate", "            self._rate = sample_rate", P, "the microphone reports the asked rate, not the device's"),
    ("J1", JS, "if (v > MAX_VIBRATE_MS) return INVALID; pat.push(v);", "pat.push(v);", W, "the host passes a pattern entry over 5000 ms to the browser"),
    ("J2", JS, "chromium ? [r.alpha, r.beta, r.gamma] : [r.beta, r.gamma, r.alpha]", "chromium ? [r.beta, r.gamma, r.alpha] : [r.beta, r.gamma, r.alpha]", W, "Chrome's rotation rate axes are read with the W3C mapping"),
    ("J2b", JS, "chromium ? [r.alpha, r.beta, r.gamma] : [r.beta, r.gamma, r.alpha]", "chromium ? [r.alpha, r.beta, r.gamma] : [r.alpha, r.beta, r.gamma]", W, "another browser's rotation rate axes are read with Chrome's mapping"),
    ("J3", JS, "if (!motion.running || motion.seq === motion.readSeq) return 0;", "if (!motion.running) return 0;", W, "a motion sample can be read twice"),
    ("J4", JS, "    if (!doc?.fullscreenElement) orientLocked = false; // leaving fullscreen releases the lock\n", "", W, "the orientation flag stays after fullscreen ends"),
    ("J5", JS, "      ptr.dx = 0; ptr.dy = 0;\n      return 1;", "      return 1;", W, "a pointer delta is not cleared when read"),
    ("J6", JS, "      if (need > Number(cap)) return -1n; // the frame stays; nothing is counted until it is taken\n", "", W, "a camera frame is written past a too small buffer"),
    ("J7", JS, "      if (camSeq !== 0) camSkipped += seq - camSeq - 1;", "", W, "skipped camera frames are not counted"),
    ("J7b", JS, "      if (need > Number(cap)) return -1n; // the frame stays; nothing is counted until it is taken\n      if (camSeq !== 0) camSkipped += seq - camSeq - 1; // frames the camera made that the game never read\n", "      if (camSeq !== 0) camSkipped += seq - camSeq - 1; // frames the camera made that the game never read\n      if (need > Number(cap)) return -1n;\n", W, "skipped frames are counted again on every read with a too small buffer"),
    ("J8", JS, "{ start = (start + 1) % cap; len--; over++; }", "{ start = (start + 1) % cap; len--; }", W, "discarded microphone samples are not counted"),
    ("J9", JS, "      if (cam || camBusy) return BUSY;\n", "", W, "a second camera open is accepted"),
    ("J10", JS, 'e?.name === "SecurityError") perm[key] = DENIED;', 'e?.name === "SecurityError") perm[key] = PROMPT;', W, "a refused camera or microphone prompt is not remembered"),
    ("J11", ROUTER, "self._p[].permissions[Int(self._p[].rx[PACKET_HEADER])].push(bytes^)", "self._p[].permissions[0].push(bytes^)", W, "every permission result goes to one queue"),
    ("J12", ROUTER, "elif kind > KIND_DEV_PERMISSION and kind < DEV_KIND_FIRST + DEV_KIND_COUNT:", "elif kind > 99:", W, "device results other than permissions are dropped as foreign"),
]


def run_test(name: str) -> str:
    """"killed" (a check printed [FAIL]), "survived" (exit 0), or "crashed" (non-zero exit without a failed check: the mutation does not compile or throws)."""
    cmd = [sys.executable, "scripts/test_native.py", name] if name == P else [sys.executable, "scripts/test_device.py"]
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode == 0:
        return "survived"
    return "killed" if "[FAIL]" in proc.stdout + proc.stderr else "crashed"


def main(argv: list[str]) -> int:
    chosen = [m for m in MUTATIONS if not argv or m[0] in argv]
    originals: dict[str, str] = {}
    escaped = 0
    try:
        for mid, rel, old, new, test, rule in chosen:
            path = ROOT / rel
            originals.setdefault(rel, path.read_text())
            text = originals[rel]
            if text.count(old) != 1:
                print(f"{mid}: source text for the mutation not found exactly once in {rel}; update scripts/mutation_device.py")
                return 2
            path.write_text(text.replace(old, new))
            result = run_test(test)
            path.write_text(text)
            escaped += 0 if result == "killed" else 1
            print(f"{mid} [{test}] {rule}: {'a check FAILED as required' if result == 'killed' else result.upper()}", flush=True)
    finally:
        for rel, text in originals.items():
            (ROOT / rel).write_text(text)
    return 1 if escaped else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
