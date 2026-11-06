#!/usr/bin/env python3
"""Build and run a native Mojo test of this repo.

    pixi run -e wasm test-editor        # tests/editor_command.mojo (needs the engine)
    pixi run -e wasm test-ui            # tests/ui_*.mojo (standard library only: ui/ stands alone)

Each test is a program that exits non-zero on a failed check. `ui_*` tests are built without the engine on the
include path, which is the check that `ui/` imports nothing but the standard library."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
import build_core  # noqa: E402


def run_test(name: str) -> int:
    entry = f"tests/{name}.mojo"
    out = build_core.build_native(entry, ROOT / f"build/{name}", asserts=True, engine=not name.startswith("ui_"))
    return subprocess.run([str(out)], cwd=ROOT).returncode


def main(argv: list[str]) -> int:
    names = argv or sorted(p.stem for p in (ROOT / "tests").glob("ui_*.mojo"))
    if not names:
        sys.exit("test_native: no tests named and no tests/ui_*.mojo found")
    rc = 0
    for n in names:
        rc |= run_test(n)
    return 1 if rc else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
