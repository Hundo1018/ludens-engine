#!/usr/bin/env python3
"""B4 step 1+2: world hash and PCM hash, native against wasm64, from app/parity.mojo. Equality, not tolerance."""
import re
import subprocess
import sys
from pathlib import Path

from ludens_wasm_rt import parity

ROOT = Path(__file__).resolve().parent.parent
D = ROOT / "build/deps"
FRAMES, BLOCKS = 240, 4
sys.path.insert(0, str(ROOT / "scripts"))
from bench import build, serial_engine  # noqa: E402  (the same driver wrapper and serial-native engine copy)


def entry_build(entry: str, libs: list[Path], includes: list[Path], *extra: str) -> None:
    cmd = [sys.executable, "-m", "ludens_wasm_rt.build_wasm"]
    for lib in libs:
        cmd += ["--lib", str(lib)]
    for inc in includes:
        cmd += ["-I", str(inc)]
    proc = subprocess.run([*cmd, entry, *extra], cwd=ROOT, capture_output=True, text=True)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def main() -> int:
    subprocess.run(["bash", "scripts/deps.sh"], cwd=ROOT, check=True)
    import native_libs
    native_libs.build_all()
    ma = D / "miniaudio-mojo"
    inc = [ma, ma / "examples/web", ROOT / "app"]
    eng = serial_engine()
    entry_build("app/parity.mojo", [eng, ma, Path(".")], [eng, *inc], "--target", "native", "-o", "build/parity")
    entry_build("app/parity.mojo", [D / "ludens-core", ma, Path(".")], [D / "ludens-core", *inc],
                "--target", "wasm64", "-o", "build/parity.wasm", "--export", "parity_*")
    out = subprocess.run([str(ROOT / "build/parity")], capture_output=True, text=True, check=True).stdout
    nat = re.search(r"world (\d+) pcm (\d+) contacts (\d+)", out)
    wasm = parity.wasm_u64s(ROOT / "build/parity.wasm", "parity_run", 3, [FRAMES, BLOCKS])
    ok = parity.compare(["world hash", "pcm hash", "contacts"], [int(v) for v in nat.groups()], wasm, "parity (world, pcm)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
