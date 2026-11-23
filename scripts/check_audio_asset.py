#!/usr/bin/env python3
"""The audio assets (#120): the committed files are what scripts/assets/gen_audio.py makes, and a built site that ships audio
carries `audio-LICENSE.txt` with the copyright line.

    pixi run -e wasm test-audio-assets
    python3 scripts/check_audio_asset.py --built build/web      # what build_web.py calls"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIR = ROOT / "assets/audio"
COPYRIGHT = "Copyright (c) 2026 Hundo1018"
SHIPPED = ("calm_pad.lsound", "calm_perc.lsound", "tense_pad.lsound", "music.music")


def copy_to_build(out: Path) -> None:
    """Copy the clips, the track list and the license into the site (clips under audio/, the license beside them)."""
    (out / "audio").mkdir(parents=True, exist_ok=True)
    for name in SHIPPED:
        shutil.copy(DIR / name, out / "audio" / name)
    shutil.copy(DIR / "LICENSE.txt", out / "audio-LICENSE.txt")
    (out / "audio" / "index.txt").write_text("\n".join(SHIPPED) + "\n", encoding="utf-8")


def check_built(out: Path) -> list[str]:
    """Problems with the audio in a built site: any .lsound in audio/ needs `audio-LICENSE.txt` with the copyright and MIT text."""
    audio = out / "audio"
    if not audio.is_dir() or not any(audio.glob("*.lsound")):
        return []
    lic = out / "audio-LICENSE.txt"
    if not lic.is_file():
        return ["audio/ is built without audio-LICENSE.txt"]
    text = lic.read_text(encoding="utf-8")
    return [f"audio-LICENSE.txt lacks {what!r}" for what in (COPYRIGHT, "MIT License") if what not in text]


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--built":
        problems = check_built(Path(sys.argv[2]))
        print("check_audio_asset --built:", "; ".join(problems) if problems else "ok")
        return 1 if problems else 0
    problems = []
    gen = subprocess.run([sys.executable, str(ROOT / "scripts/assets/gen_audio.py"), "--check"], capture_output=True, text=True, check=False)
    print(gen.stdout.strip())
    if gen.returncode:
        problems.append("assets/audio differs from scripts/assets/gen_audio.py")
    lic = (DIR / "LICENSE.txt").read_text(encoding="utf-8")
    for what in (COPYRIGHT, "MIT License"):
        if what not in lic:
            problems.append(f"assets/audio/LICENSE.txt lacks {what!r}")
    for name in SHIPPED:
        if name not in (DIR / "README.md").read_text(encoding="utf-8"):
            problems.append(f"assets/audio/README.md does not list {name}")
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:  # selftest of the built check: a site without the license is refused
        site = Path(tmp)
        copy_to_build(site)
        if check_built(site):
            problems.append("a site built with the license fails its own check: " + "; ".join(check_built(site)))
        (site / "audio-LICENSE.txt").unlink()
        if not check_built(site):
            problems.append("a site built without audio-LICENSE.txt passes the check")
    print("check_audio_asset:", "; ".join(problems) if problems else "ok")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
