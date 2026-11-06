#!/usr/bin/env python3
"""ludens build --target web (ludens-shell #15): reproducible output and the failure paths.

    pixi run -e wasm test-build

Builds the web target twice from a clean build/web and compares the two MANIFEST.sha256 files byte for byte, then checks
the files a browser needs are there, that the manifest matches the files on disk, and that the unsupported targets
exit non-zero without touching build/web. Builds the wasm64 module twice, so it takes a few minutes."""
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LUDENS = [sys.executable, str(ROOT / "scripts/ludens.py")]
WEB = ROOT / "build/web"
passed = failed = 0


def check(cond: bool, label: str) -> None:
    global passed, failed
    if cond:
        passed += 1
        print("  [PASS]", label)
    else:
        failed += 1
        print("  [FAIL]", label)


def build() -> subprocess.CompletedProcess:
    return subprocess.run([*LUDENS, "build", "--target", "web"], cwd=ROOT, capture_output=True, text=True)


def main() -> int:
    shutil.rmtree(WEB, ignore_errors=True)
    r1 = build()
    check(r1.returncode == 0, "first build exits 0" + ("" if r1.returncode == 0 else f": {(r1.stdout + r1.stderr)[-400:]}"))
    m1 = (WEB / "MANIFEST.sha256").read_text(encoding="utf-8") if (WEB / "MANIFEST.sha256").exists() else ""
    names = {line.split("  ")[2] for line in m1.splitlines()}
    need = {"app.wasm", "index.html", "app.js", "host.mjs", "worklet.js", "pixel_tolerance.json"}
    check(need <= names, f"the files a browser needs are listed ({sorted(need - names) or 'all present'})")
    ok = True
    for line in m1.splitlines():
        digest, size, name = line.split("  ")
        data = (WEB / name).read_bytes()
        ok &= hashlib.sha256(data).hexdigest() == digest and len(data) == int(size)
    check(ok and len(m1) > 0, "every manifest line matches its file (sha256 and size)")
    check(m1.splitlines() == sorted(m1.splitlines(), key=lambda l: l.split("  ")[2]), "the manifest is sorted by path")

    shutil.rmtree(WEB, ignore_errors=True)
    (ROOT / "build/app.wasm").unlink(missing_ok=True)
    r2 = build()
    m2 = (WEB / "MANIFEST.sha256").read_text(encoding="utf-8") if (WEB / "MANIFEST.sha256").exists() else ""
    check(r2.returncode == 0 and m1 == m2 and m1 != "", "a second build from scratch gives a byte-identical manifest (wasm module included)")

    before = (WEB / "MANIFEST.sha256").read_bytes()
    for target in ("native", "android"):
        r = subprocess.run([*LUDENS, "build", "--target", target], cwd=ROOT, capture_output=True, text=True)
        check(r.returncode != 0 and "not implemented" in r.stderr, f"--target {target} exits non-zero and says it is not implemented")
    check((WEB / "MANIFEST.sha256").read_bytes() == before, "...and leaves build/web as it was")

    print(f"build: {passed} / {passed + failed} checks")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
