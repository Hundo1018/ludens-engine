#!/usr/bin/env python3
"""Synthesize the music assets in assets/audio/ (ludens-engine #120): `.lsound` files (scripts/assets/convert_wav.py's format:
48 kHz, mono, 16-bit) and the `music.music` track list.

    pixi run -e wasm python3 scripts/assets/gen_audio.py            # write assets/audio/*.lsound
    pixi run -e wasm python3 scripts/assets/gen_audio.py --check    # compare the committed files with a fresh synthesis

Nothing is sampled from a recording: every sample is computed here from sums of sine partials, a decaying sine and a linear
congruential noise, with + - * / only (the sine is a Taylor series), so the bytes are the same on every platform and the
`--check` hash comparison cannot drift with a libm. The clips are loops: each partial's frequency is a multiple of
1 / loop-length, so the last sample continues into the first without a click."""
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "assets/audio"
RATE = 48000
BPM = 120
BEATS = 4
BAR = RATE * 60 * BEATS // BPM  # 96000 frames
LOOP = 2 * BAR  # two bars
TAU = 6.283185307179586


def sin(x: float) -> float:
    """sine from a Taylor series after reducing to [-pi, pi]: +, -, *, / only."""
    x = x - TAU * int(x / TAU + (0.5 if x >= 0 else -0.5))
    term, total = x, x
    for k in range(1, 12):
        term *= -x * x / ((2 * k) * (2 * k + 1))
        total += term
    return total


def pad(freqs: list[float], amps: list[float]) -> list[float]:
    out = []
    for i in range(LOOP):
        t = i / RATE
        s = sum(a * sin(TAU * f * t) for f, a in zip(freqs, amps, strict=True))
        swell = 0.75 + 0.25 * sin(TAU * t / (LOOP / RATE))  # one slow swell per loop
        out.append(s * swell)
    return out


def perc() -> list[float]:
    """A kick on every beat (a sine falling from 140 to 55 Hz over 120 ms) and a short noise tick on every off-beat."""
    out = [0.0] * LOOP
    beat = RATE * 60 // BPM
    state = 12345
    for b in range(2 * BEATS):
        start = b * beat
        phase = 0.0
        for i in range(int(0.25 * RATE)):
            t = i / RATE
            f = 55.0 + 85.0 * (1.0 - min(t / 0.12, 1.0)) ** 2
            phase += TAU * f / RATE
            out[start + i] += 0.5 * sin(phase) * (1.0 - t / 0.25) ** 2
        tick = start + beat // 2
        for i in range(int(0.04 * RATE)):
            state = (state * 1103515245 + 12345) & 0x7FFFFFFF
            out[tick + i] += 0.12 * ((state / 0x3FFFFFFF) - 1.0) * (1.0 - i / (0.04 * RATE))
    return out


def tracks() -> dict[str, list[float]]:
    return {
        "calm_pad": pad([110.0, 130.75, 164.75, 220.0], [0.16, 0.12, 0.10, 0.05]),
        "calm_perc": perc(),
        "tense_pad": pad([110.0, 116.5, 220.0, 233.0], [0.18, 0.12, 0.06, 0.04]),
    }


MUSIC_TEXT = """# Track list for the music mixer (app/audio_assets.mojo parse_music). A layer is a clip name: the .lsound file without its suffix.
# Every layer of a track has the same length (two bars); a request to change track takes effect at the next bar line.
track calm
  bpm 120
  beats 4
  layers calm_pad calm_perc
track tense
  bpm 120
  beats 4
  layers tense_pad
"""


def lsound(samples: list[float], name: str) -> bytes:
    pcm = [max(-32768, min(32767, int(round(s * 32767)))) for s in samples]
    header = json.dumps({"name": name, "rate": RATE, "channels": 1, "frames": len(pcm), "source_rate": RATE,
                         "source_frames": len(pcm), "peak": max(abs(p) for p in pcm) / 32768}, separators=(",", ":")).encode()
    return b"LSND" + struct.pack("<II", 1, len(header)) + header + struct.pack(f"<{len(pcm)}h", *pcm)


def files() -> dict[str, bytes]:
    out = {f"{name}.lsound": lsound(s, name) for name, s in tracks().items()}
    out["music.music"] = MUSIC_TEXT.encode()
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="fail if a committed file differs from a fresh synthesis")
    args = ap.parse_args()
    fresh = files()
    if args.check:
        bad = [n for n, b in fresh.items() if not (OUT / n).is_file() or (OUT / n).read_bytes() != b]
        for n in bad:
            print(f"gen_audio: {n} differs from a fresh synthesis")
        print("gen_audio --check:", "FAIL" if bad else f"{len(fresh)} files identical")
        return 1 if bad else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, b in fresh.items():
        (OUT / n).write_bytes(b)
        print(f"{n}: {len(b)} bytes, sha256 {hashlib.sha256(b).hexdigest()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
