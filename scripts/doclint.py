"""Check that file paths cited in the docs exist (ROADMAP 17.82).

    pixi run doclint              # check the repo, exit 1 on a dead reference
    pixi run doclint -- --list    # also print every reference found
    pixi run doclint -- --selftest

A reference is a backticked repo path such as `physics/solver6.mojo:120` or
`tests/test_vec.mojo`. Only paths under a top-level directory that exists in
the repo are considered, so prose like `a/b` is ignored. A dead reference is
allowed only when `scripts/doclint_allow.txt` lists it with a reason
(historical paths that were moved or deleted, files an item plans to add).

The README's test count, when it states one, must match the number of
`tests/test_*.mojo` files.
"""

import argparse
import re
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ["README.md", "CLAUDE.md", "CONTRIBUTING.md", "docs/ROADMAP.md", "docs/ARCHITECTURE.md", "docs/CATEGORY.md"]
ALLOW = "scripts/doclint_allow.txt"
# `dir/sub/file.ext` with an optional `:line` or `:a-b` suffix, inside backticks.
REF = re.compile(r"`([A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)+\.(?:mojo|md|toml|sh|py|h|txt|in|yml))(?::[0-9,\- ]+)?`")
TEST_COUNT = re.compile(r"\b(\d+) (?:self-checking )?test programs\b")


def load_allow(root: Path) -> dict[str, str]:
    """path -> reason. Format: `path  # reason`, one per line."""
    out = {}
    f = root / ALLOW
    if not f.exists():
        return out
    for line in f.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        path, _, reason = line.partition("#")
        path = path.strip()
        if not reason.strip():
            raise SystemExit(f"doclint: {ALLOW}: '{path}' has no reason")
        out[path] = reason.strip()
    return out


def refs(root: Path, doc: str) -> list[tuple[int, str]]:
    """(line number, path) for every reference in `doc` whose first segment
    is a top-level directory of the repo."""
    f = root / doc
    if not f.exists():
        return []
    tops = {p.name for p in root.iterdir() if p.is_dir()}
    found = []
    for i, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        for m in REF.finditer(line):
            path = m.group(1)
            if path.split("/", 1)[0] in tops:
                found.append((i, path))
    return found


def check(root: Path, docs: list[str], list_all: bool = False) -> list[str]:
    """Problems found, one line each (empty = clean)."""
    allow = load_allow(root)
    used_allow = set()
    problems = []
    for doc in docs:
        for line, path in refs(root, doc):
            ok = (root / path).exists()
            if list_all:
                print(f"  {'ok  ' if ok else 'DEAD'} {doc}:{line} {path}")
            if ok:
                continue
            if path in allow:
                used_allow.add(path)
                continue
            problems.append(f"dead reference {doc}:{line} `{path}`")
    for path in sorted(set(allow) - used_allow):
        if (root / path).exists():
            problems.append(f"stale allow entry `{path}` (the file exists now)")
    readme = root / "README.md"
    if readme.exists():
        m = TEST_COUNT.search(readme.read_text(encoding="utf-8"))
        if m:
            have = len(list((root / "tests").glob("test_*.mojo")))
            if int(m.group(1)) != have:
                problems.append(f"README.md states {m.group(1)} test programs, tests/ has {have}")
    return problems


def selftest() -> int:
    """Fixtures: a clean tree passes; a dead path, an unexplained allow entry,
    a stale allow entry and a wrong README count each fail."""
    fails = 0

    def tree(files: dict[str, str]) -> Path:
        d = Path(tempfile.mkdtemp(prefix="doclint_"))
        for p, text in files.items():
            (d / p).parent.mkdir(parents=True, exist_ok=True)
            (d / p).write_text(text, encoding="utf-8")
        return d

    def expect(name: str, root: Path, want_problems: int):
        nonlocal fails
        try:
            got = check(root, ["README.md", "docs/ROADMAP.md"])
            n = len(got)
        except SystemExit as e:
            got, n = [str(e)], -1
        ok = n == want_problems
        fails += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] doclint selftest - {name} (problems {n}, want {want_problems}) {got}")

    base = {
        "physics/a.mojo": "",
        "tests/test_a.mojo": "",
        "tests/test_b.mojo": "",
        "README.md": "run 2 test programs, see `tests/test_a.mojo` and a/b prose\n",
        "docs/ROADMAP.md": "see `physics/a.mojo:12-20` and `nothere/x.mojo` (not a repo dir)\n",
    }
    expect("clean tree", tree(base), 0)
    expect("dead path", tree({**base, "docs/ROADMAP.md": "`physics/gone.mojo`\n"}), 1)
    expect(
        "allowed dead path",
        tree({**base, "docs/ROADMAP.md": "`physics/gone.mojo`\n", ALLOW: "physics/gone.mojo  # moved in 2.3\n"}),
        0,
    )
    expect("allow entry without reason", tree({**base, ALLOW: "physics/gone.mojo\n"}), -1)
    expect("stale allow entry", tree({**base, ALLOW: "physics/a.mojo  # old\n"}), 1)
    expect("wrong README count", tree({**base, "README.md": "run 160 test programs\n"}), 1)
    print(f"[{'PASS' if fails == 0 else 'FAIL'}] doclint selftest - {6 - fails} / 6 checks")
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems = check(ROOT, DOCS, a.list)
    for p in problems:
        print("doclint:", p)
    total = sum(len(refs(ROOT, d)) for d in DOCS)
    print(f"doclint: {'PASS' if not problems else 'FAIL'} ({total} references, {len(problems)} problems)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
