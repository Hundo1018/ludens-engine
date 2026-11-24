#!/usr/bin/env python3
"""The audio mixer inside the real app (#120), under node: the shipped files load through app_load_audio, the music plays and
reads a plausible loudness, a muted bus is silent, a bad file is refused, and a jump logs its cue and is heard.

    pixi run -e wasm test-audio-app"""
import json
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"


def main() -> int:
    subprocess.run(["bash", "scripts/build_wasm.sh"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    sys.path.insert(0, str(ROOT / "scripts"))
    import check_audio_asset
    site = ROOT / "build/audio_app_site"
    check_audio_asset.copy_to_build(site)
    run = subprocess.run(["node", str(ROOT / "scripts/audio_app.mjs"), str(ROOT / "build/app.wasm"), str(ludens_wasm_rt.HOST_MJS),
                          str(D / "wgpu-mojo"), str(D / "miniaudio-mojo"), str(site / "audio")], capture_output=True, text=True, check=False)
    if run.returncode:
        sys.exit("audio_app: " + (run.stdout + run.stderr)[-2000:])
    r = json.loads(run.stdout.strip().splitlines()[-1])
    print(json.dumps(r, indent=1))
    checks = {
        "all four files load": r["files"] == 4 and r["loadCodes"] == [0, 0, 0, 0],
        "a file that is not an .lsound is refused": r["garbage"] == -1,
        "an unknown file type is refused": r["unknownType"] == -1,
        "an unknown track is refused": r["noTrack"] == -1,
        "the calm track starts": r["calmCode"] == 0,
        "one second of music is audible (rms 0.005 .. 0.5)": 0.005 < r["rmsMusic"] < 0.5,
        "its momentary loudness is plausible (-45 .. -10 LUFS)": -45 < r["momentary"] < -10,
        "the integrated loudness is readable (-45 .. -10 LUFS)": -45 < r["integrated"] < -10,
        "the music bus muted: silent": r["rmsMuted"] == 0.0,
        "a bus number out of range is refused": r["busBad"] == -1,
        "the jump logs cue 1 once": r["events"].count('"cue":1') == 1 and r["events"].count('"cue"') == 1,
        "the jump is heard with the music muted (rms > 0.001)": r["rmsJump"] > 0.001,
    }
    for label, ok in checks.items():
        print("  [PASS]" if ok else "  [FAIL]", label)
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
