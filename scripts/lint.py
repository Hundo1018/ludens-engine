"""Fast static checks in one command: `pixi run -e wasm lint` (no build, no GPU).

    pixi run -e wasm lint                # every check, one line each; exit 1 if any fails
    pixi run -e wasm lint -- --only ruff,shellcheck
    pixi run -e wasm lint -- --list

Each check prints its own findings under its line. The checks (ported from ludens-core's scripts/lint.py):

  code-rules   Mojo rules a script can check reliably (scripts/code_rules.py)
  stale-refs   comments and docs that name code which does not exist (scripts/stale_refs.py)
  ruff         the repo's Python: the bug-finding rules in ruff.toml
  shellcheck   scripts/*.sh
  gen-table    game/demo_table.mojo is what scripts/gen_table.py writes from game/data/demo.schema (#119)
  gen-actions  game/demo_actions.mojo is what scripts/gen_actions.py writes from game/data/demo.actions (#117)
  selftests    the selftests of code_rules and stale_refs

CI runs it in the `directory rules` job (.github/workflows/editor.yml), next to check-layout.
"""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PY = sys.executable


def shell_files() -> list[str]:
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / "scripts").glob("*.sh"))


CHECKS = {
    "code-rules": lambda: [PY, "scripts/code_rules.py"],
    "stale-refs": lambda: [PY, "scripts/stale_refs.py"],
    "ruff": lambda: ["ruff", "check", "--quiet", "--output-format", "concise", "."],
    "shellcheck": lambda: ["shellcheck", "-f", "gcc", *shell_files()],
    "gen-table": lambda: [PY, "scripts/gen_table.py", "game/data/demo.schema", "--table", "game/data/demo.table", "-o", "game/demo_table.mojo", "--check"],
    "gen-actions": lambda: [PY, "scripts/gen_actions.py", "--check"],
    "selftests": lambda: None,
}


def run(argv: list[str]) -> tuple[bool, str]:
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True, check=False)
    except FileNotFoundError:
        return False, f"{argv[0]} not found (run through pixi: `pixi run -e wasm lint`)"
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def run_check(name: str) -> tuple[bool, str]:
    if name == "selftests":
        outs, ok = [], True
        for s in ("scripts/code_rules.py", "scripts/stale_refs.py"):
            good, out = run([PY, s, "--selftest"])
            ok = ok and good
            if not good:
                outs.append(out)
        return ok, "\n".join(outs)
    return run(CHECKS[name]())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma-separated subset of: " + ", ".join(CHECKS))
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        print("\n".join(CHECKS))
        return 0
    names = a.only.split(",") if a.only else list(CHECKS)
    unknown = [n for n in names if n not in CHECKS]
    if unknown:
        print("lint: unknown check(s): " + ", ".join(unknown))
        return 2
    failed = []
    for n in names:
        ok, out = run_check(n)
        print(f"[lint] {'ok  ' if ok else 'FAIL'} {n}")
        if not ok:
            failed.append(n)
            for line in out.splitlines():
                print("    " + line)
    if failed:
        print("lint: failed: " + ", ".join(failed))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
