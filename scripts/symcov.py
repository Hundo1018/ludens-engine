"""Symbol-level test coverage, an approximation (ROADMAP 17.82).

    pixi run symcov                   # per package: public names a test imports
    pixi run symcov -- --list physics # the untested names of one package
    pixi run symcov -- --selftest

Mojo 1.1.0 has no line-coverage tool, so this answers a narrower question: of
the PUBLIC top-level names an engine module defines (`def` / `struct` /
`trait` / `comptime` at column 0, not starting with `_`), which ones does some
file under tests/ import by name (`from pkg.mod import A, B`, or `from pkg
import A` for a package re-export)? It is NOT line coverage: a name imported
and never called counts as covered, and a name exercised only through another
name (a helper called by a tested function) counts as uncovered. It reports;
it does not gate.
"""

import argparse
import re
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEF = re.compile(r"^(?:def|struct|trait|comptime)\s+([A-Za-z][A-Za-z0-9_]*)", re.M)
FROM = re.compile(r"^\s*from\s+([a-z_][a-z0-9_.]*)\s+import\s+(\([^)]*\)|[^\n]+)", re.M)


def packages(root: Path) -> list[str]:
    return sorted(tomllib.loads((root / "scripts/arch_layers.toml").read_text(encoding="utf-8"))["layers"])


def public_names(root: Path) -> dict[str, set[str]]:
    """`pkg.mod` -> public names defined there."""
    out = {}
    for p in packages(root):
        for f in sorted((root / p).glob("*.mojo")):
            if f.stem == "__init__":
                continue
            out[f"{p}.{f.stem}"] = {m.group(1) for m in DEF.finditer(f.read_text(encoding="utf-8"))}
    return out


def imported(root: Path) -> set[tuple[str, str]]:
    """(module or package, name) pairs imported by tests."""
    got = set()
    for f in (root / "tests").glob("*.mojo"):
        for m in FROM.finditer(f.read_text(encoding="utf-8")):
            names = m.group(2).strip().strip("()")
            for part in names.replace("\n", " ").split(","):
                name = part.strip().split(" as ")[0].strip()
                if name:
                    got.add((m.group(1), name))
    return got


def coverage(root: Path) -> dict[str, tuple[int, int, list[str]]]:
    """package -> (covered, total, uncovered `mod.Name` list)."""
    pubs = public_names(root)
    imp = imported(root)
    res: dict[str, tuple[int, int, list[str]]] = {}
    for mod, names in sorted(pubs.items()):
        pkg = mod.split(".")[0]
        cov, tot, miss = res.get(pkg, (0, 0, []))
        for n in sorted(names):
            tot += 1
            if (mod, n) in imp or (pkg, n) in imp:
                cov += 1
            else:
                miss.append(f"{mod}.{n}")
        res[pkg] = (cov, tot, miss)
    return res


def selftest() -> int:
    d = Path(tempfile.mkdtemp(prefix="symcov_"))
    files = {
        "scripts/arch_layers.toml": "[layers]\nlow = 0\n",
        "low/a.mojo": "def used():\n    pass\nstruct Also:\n    pass\ndef _private():\n    pass\ndef unused():\n    pass\n    def nested(): pass\n",
        "low/b.mojo": "comptime K = 3\n",
        "tests/test_x.mojo": "from low.a import (\n    used,\n    Also as A2,\n)\nfrom low import K\n",
    }
    for p, t in files.items():
        (d / p).parent.mkdir(parents=True, exist_ok=True)
        (d / p).write_text(t, encoding="utf-8")
    cov, tot, miss = coverage(d)["low"]
    checks = [
        ("multi-line import, alias and package re-export count", cov == 3, cov),
        ("private and nested names are not public", tot == 4, tot),
        ("unimported public name reported", miss == ["low.a.unused"], miss),
    ]
    for name, ok, detail in checks:
        print(f"  [{'PASS' if ok else 'FAIL'}] symcov selftest - {name} ({detail})")
    n = sum(1 for _, ok, _ in checks if ok)
    print(f"[{'PASS' if n == len(checks) else 'FAIL'}] symcov selftest - {n} / {len(checks)} checks")
    return 0 if n == len(checks) else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", metavar="PKG")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    res = coverage(ROOT)
    if a.list:
        for name in res[a.list][2]:
            print(f"  {name}")
        return 0
    allc = sum(c for c, _, _ in res.values())
    allt = sum(t for _, t, _ in res.values())
    for pkg, (c, t, _) in res.items():
        print(f"symcov: {pkg:12s} {c:4d} / {t:4d} public names imported by a test ({100 * c / max(t, 1):5.1f} %)")
    print(f"symcov: total {allc} / {allt} ({100 * allc / max(allt, 1):.1f} %) -- symbol-level, not line coverage")
    return 0


if __name__ == "__main__":
    sys.exit(main())
