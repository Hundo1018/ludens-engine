#!/usr/bin/env python3
"""Show that each audio behavior test (#120) fails when the behavior breaks: apply one source mutation at a time, run the test
that covers it, expect a failure, restore the file.

    pixi run -e wasm python3 scripts/mutate_audio.py            # every mutation (about a minute each)
    pixi run -e wasm python3 scripts/mutate_audio.py 3 5        # by number

A mutation whose test still passes is reported as SURVIVED and the script exits 1. The files are restored even on an error."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
NATIVE = ["python3", "scripts/test_audio.py", "audio_mixer"]
DEMO = ["python3", "scripts/test_native.py", "demo_mode"]
SAME = ["python3", "scripts/audio_same.py"]

# (what breaks, file, old text, new text, command, text that must appear in the failing output)
MUTATIONS = [
    ("concurrency limit off by one", "app/mixer.mojo", "if count >= limit:", "if count > limit:", NATIVE, "limit 2: two voices"),
    ("a muted bus still sounds", "app/mixer.mojo", "self.bus_gain[bus] = 0.0 if self.bus_mute[bus] else db_to_gain(self.bus_db[bus])",
     "self.bus_gain[bus] = db_to_gain(self.bus_db[bus])", NATIVE, "muted bus is exactly silent"),
    ("ducking never engages", "app/mixer.mojo", "var target = self.duck_gain_target if self.duck_env > self.duck_threshold else Float32(1.0)",
     "var target = Float32(1.0)", NATIVE, "the music is at -12 dB"),
    ("no distance attenuation", "app/mixer.mojo", "set_attenuation_model(AttenuationModel.INVERSE)",
     "set_attenuation_model(AttenuationModel.NONE)", NATIVE, "left source, left ear: 1/d"),
    ("the listener ignores the camera's direction", "app/mixer.mojo", "        self.listener.set_direction(fx, fy, fz)\n", "", NATIVE, "listener facing +x"),
    ("track change one frame late", "app/music.mojo", "if self.pos % bar == 0 and self._has_pending():",
     "if (self.pos - 1) % bar == 0 and self._has_pending():", NATIVE, "the bar line frame is track 1"),
    ("loudness meter without the high-shelf stage", "app/loudness.mojo", "var l = self.high_l.tick(self.shelf_l.tick(Float64(stereo[2 * i])))",
     "var l = self.high_l.tick(Float64(stereo[2 * i]))", NATIVE, "momentary loudness of a -23 dBFS"),
    ("the event's pitch is not drawn from the seed", "app/mixer.mojo", "var pitch = self.rng.range(self.events[event].pitch_lo, self.events[event].pitch_hi)",
     "var pitch = Float32(1.0)", NATIVE, "pitch stays in 0.8 .. 1.2 and covers it"),
    ("an impact is raised for a contact that is not new", "game/demo_mode.mojo", "if e.kind != Int64(EVENT_BEGAN) or e.impulse < IMPACT_MIN_IMPULSE:",
     "if e.impulse < IMPACT_MIN_IMPULSE:", DEMO, "impact"),
    ("native shim uses the approximate rsqrt", "scripts/native_libs.py", 'SHIM_DEFINES = ["-DMA_NO_SSE2"]', "SHIM_DEFINES = []", SAME, "DIFFERENT"),
]


def run_one(i: int) -> bool:
    what, rel, old, new, cmd, expect = MUTATIONS[i]
    path = ROOT / rel
    original = path.read_text()
    if original.count(old) != 1:
        print(f"[{i}] {what}: the text to mutate occurs {original.count(old)} times in {rel}")
        return False
    path.write_text(original.replace(old, new))
    try:
        proc = subprocess.run(["pixi", "run", "-e", "wasm", *cmd], cwd=ROOT, capture_output=True, text=True, check=False)
    finally:
        path.write_text(original)
    out = proc.stdout + proc.stderr
    fails = [line.strip() for line in out.splitlines() if "[FAIL]" in line or "DIFFERENT" in line]
    killed = proc.returncode != 0 and any(expect in line for line in fails)
    print(f"[{i}] {what}: {'KILLED' if killed else 'SURVIVED'} ({rel})")
    for line in fails[:3]:
        print("      ", line[:200])
    if proc.returncode != 0 and not fails:
        print("      build or run error:", out[-600:])
    return killed


def main() -> int:
    picks = [int(a) for a in sys.argv[1:]] or list(range(len(MUTATIONS)))
    results = [run_one(i) for i in picks]
    print(f"mutations: {sum(results)} / {len(results)} killed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
