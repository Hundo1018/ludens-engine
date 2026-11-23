"""Mojo rules that a script can check reliably, adapted from ludens-core's scripts/code_rules.py.

    pixi run -e wasm code-rules                 # exit 1 on a violation
    pixi run -e wasm code-rules -- --selftest

Checked (on the code with comments and docstrings removed, scripts/stale_refs.py `strip_mojo`):

  bare-case     `case NAME:` binds a new variable called NAME and matches every value; a named constant is
                compared with `case == NAME:`. Any `case` followed by an upper-case name is reported. This is a fact
                of the language, not a style: it holds in every Mojo repo. 0 hits today (the repo has no `match`
                yet), so it guards the first one.

Measured and not checked (hit counts on 2026-11-23, 138 .mojo files):

  engine-print  ludens-core forbids `print` in engine packages. This repo states no such rule, and its 50 hits
                (38 in app/, 12 in editor/) are all native runners, probes and the `ludens-core` CLI, whose output
                is their job: every hit would be a false positive. ui/ and game/ have 0.
  todo-id       ludens-core requires a TODO to name its issue or ROADMAP entry. This repo states no such rule and
                has 0 TODO / FIXME / XXX comments, so there is nothing to check.
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stale_refs import strip_mojo  # noqa: E402  -- the one comment/docstring splitter, shared

ROOT = Path(__file__).resolve().parent.parent
SKIP = {".git", ".pixi", "build", "build64", "node_modules"}
BARE_CASE = re.compile(r"^\s*case\s+([A-Z][A-Za-z0-9_]*)\b(?!\s*\()")
STRING = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'')


def mojo_files(root: Path):
    for p in sorted(root.rglob("*.mojo")):
        rel = p.relative_to(root)
        if not any(part in SKIP for part in rel.parts):
            yield p, rel.as_posix()


def check(root: Path) -> list[str]:
    out = []
    for p, rel in mojo_files(root):
        code, _ = strip_mojo(p.read_text(encoding="utf-8", errors="ignore"))
        for i, line in enumerate(code.split("\n"), 1):
            m = BARE_CASE.match(STRING.sub('""', line))
            if m:
                out.append(f"{rel}:{i}: bare-case `case {m.group(1)}:` binds a new name; write `case == {m.group(1)}:`")
    return out


def selftest() -> int:
    with tempfile.TemporaryDirectory() as t:
        r = Path(t)
        (r / "app").mkdir()
        (r / "app/a.mojo").write_text(
            '"""case NOT_CODE: in a docstring."""\n'
            "def f(x: Int):\n"
            "    match x:\n"
            "        case == KIND_A:\n"
            "            pass\n"
            "        case KIND_B:\n"
            "            pass\n"
            "        case Point(a, b):\n"
            "            pass\n"
            "        case _:\n"
            "            pass\n"
            "    # case IN_COMMENT:\n"
        )
        got = [x.split(":")[1] for x in check(r)]
        if got != ["6"]:
            print(f"code_rules selftest FAIL: got lines {got} want ['6']")
            return 1
    print("code_rules selftest: 1 case ok")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = check(ROOT)
    for p in problems:
        print("  " + p)
    if problems:
        print(f"code_rules: {len(problems)} violation(s)")
        return 1
    print("code_rules: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
