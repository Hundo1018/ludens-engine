"""Which engine modules nothing in the engine or the examples imports (ROADMAP 17.82).

    pixi run orphans                # report + gate against scripts/orphans_allow.txt
    pixi run orphans -- --all       # also list who imports every module
    pixi run orphans -- --selftest

A module counts as wired in ("接上專案", test standard v3) when a module of
another engine package, a sibling module of its own package, or an example
imports it. A module imported only by tests / benchmarks / experiments is a
leaf -- legitimate for a seam variant that only parity tests and benches
select, a gap otherwise -- and must be listed in `scripts/orphans_allow.txt`
with the reason. A module nothing imports at all is reported unless the same file lists it
(an entry point such as `embed/capi.mojo`, a documentation-only module).

Imports recognised: `from pkg.mod import`, `import pkg.mod`, `from .mod import`
inside the package, and a package `__init__.mojo` re-export (`from .mod import`
there) when the package itself is imported by an engine module or an example.
"""

import argparse
import re
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOW = "scripts/orphans_allow.txt"
CONSUMERS_WIRED = ["examples"]
CONSUMERS_LEAF = ["tests", "benchmarks", "experiments"]
FROM_ABS = re.compile(r"^\s*from\s+([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\s+import\b", re.M)
IMPORT_ABS = re.compile(r"^\s*import\s+([a-z_][a-z0-9_]*)\.([a-z_][a-z0-9_]*)\b", re.M)
FROM_REL = re.compile(r"^\s*from\s+\.([a-z_][a-z0-9_]*)\s+import\b", re.M)
FROM_PKG = re.compile(r"^\s*from\s+([a-z_][a-z0-9_]*)\s+import\b", re.M)


def packages(root: Path) -> list[str]:
    t = tomllib.loads((root / "scripts/arch_layers.toml").read_text(encoding="utf-8"))
    return sorted(t["layers"])


def scan(root: Path) -> tuple[dict[str, set[str]], list[str]]:
    """module (`pkg.mod`) -> set of importer labels, and the module list.
    Importer labels: `pkg.mod` for engine modules, `examples/x.mojo` etc."""
    pkgs = packages(root)
    mods = []
    for p in pkgs:
        for f in sorted((root / p).glob("*.mojo")):
            if f.stem != "__init__":
                mods.append(f"{p}.{f.stem}")
    modset = set(mods)
    imp: dict[str, set[str]] = {m: set() for m in mods}
    pkg_importers: dict[str, set[str]] = {p: set() for p in pkgs}
    reexport: dict[str, set[str]] = {p: set() for p in pkgs}

    def visit(label: str, text: str, own_pkg: str | None):
        for rx in (FROM_ABS, IMPORT_ABS):
            for m in rx.finditer(text):
                key = f"{m.group(1)}.{m.group(2)}"
                if key in modset and key != label:
                    imp[key].add(label)
        for m in FROM_PKG.finditer(text):
            if m.group(1) in pkg_importers and m.group(1) != own_pkg:
                pkg_importers[m.group(1)].add(label)
        if own_pkg:
            for m in FROM_REL.finditer(text):
                key = f"{own_pkg}.{m.group(1)}"
                if key in modset and key != label:
                    if label == f"{own_pkg}.__init__":
                        reexport[own_pkg].add(key)
                    else:
                        imp[key].add(label)

    for p in pkgs:
        for f in sorted((root / p).glob("*.mojo")):
            visit(f"{p}.{f.stem}", f.read_text(encoding="utf-8"), p)
    for d in CONSUMERS_WIRED + CONSUMERS_LEAF:
        for f in sorted((root / d).rglob("*.mojo")) if (root / d).exists() else []:
            visit(str(f.relative_to(root)), f.read_text(encoding="utf-8"), None)
    for p, re_mods in reexport.items():
        for key in re_mods:
            for who in pkg_importers[p]:
                imp[key].add(who + " (via " + p + ")")
    return imp, mods


def wired(importers: set[str]) -> bool:
    return any(not any(i.startswith(c + "/") for c in CONSUMERS_LEAF) for i in importers)


def load_allow(root: Path) -> dict[str, str]:
    out = {}
    f = root / ALLOW
    if not f.exists():
        return out
    for line in f.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        mod, _, reason = line.partition("#")
        if not reason.strip():
            raise SystemExit(f"orphans: {ALLOW}: '{mod.strip()}' has no reason")
        out[mod.strip()] = reason.strip()
    return out


def check(root: Path, show_all: bool = False) -> tuple[list[str], dict[str, int]]:
    imp, mods = scan(root)
    allow = load_allow(root)
    problems = []
    counts = {"wired": 0, "leaf": 0, "none": 0}
    for m in mods:
        who = imp[m]
        if show_all:
            print(f"  {m}: {', '.join(sorted(who)) or '-'}")
        if not who:
            counts["none"] += 1
            if m not in allow:
                problems.append(f"no importer at all: {m}")
        elif wired(who):
            counts["wired"] += 1
            if m in allow:
                problems.append(f"stale allow entry: {m} is wired in now")
        else:
            counts["leaf"] += 1
            if m not in allow:
                problems.append(f"leaf (tests/benchmarks only, not allow-listed): {m}")
    for m in allow:
        if m not in imp:
            problems.append(f"allow entry for a module that does not exist: {m}")
    return problems, counts


def selftest() -> int:
    fails = 0

    def tree(files: dict[str, str]) -> Path:
        d = Path(tempfile.mkdtemp(prefix="orphans_"))
        for p, text in files.items():
            (d / p).parent.mkdir(parents=True, exist_ok=True)
            (d / p).write_text(text, encoding="utf-8")
        return d

    base = {
        "scripts/arch_layers.toml": "[layers]\nlow = 0\nhigh = 1\n",
        "low/__init__.mojo": "from .reexp import R\n",
        "low/core.mojo": "",
        "low/helper.mojo": "",
        "low/reexp.mojo": "",
        "low/variant.mojo": "",
        "high/user.mojo": "from low.core import X\nfrom low import R\n",
        "low/uses_helper.mojo": "from .helper import H\n",
        "examples/demo.mojo": "from low.uses_helper import U\nfrom high.user import Y\n",
        "tests/test_v.mojo": "from low.variant import V\n",
        ALLOW: "low.variant  # seam variant selected only by its parity test\n",
    }

    def expect(name: str, files: dict[str, str], want: int):
        nonlocal fails
        try:
            got, _ = check(tree(files))
            n = len(got)
        except SystemExit as e:
            got, n = [str(e)], -1
        ok = n == want
        fails += 0 if ok else 1
        print(f"  [{'PASS' if ok else 'FAIL'}] orphans selftest - {name} (problems {n}, want {want}) {got}")

    expect("clean tree (abs, rel, re-export, example, allowed leaf)", base, 0)
    expect("module with no importer", {**base, "low/dead.mojo": ""}, 1)
    expect("allow-listed module with no importer", {**base, "low/dead.mojo": "", ALLOW: base[ALLOW] + "low.dead  # build entry point\n"}, 0)
    expect("leaf not allow-listed", {k: v for k, v in base.items() if k != ALLOW}, 1)
    expect("stale allow entry", {**base, ALLOW: base[ALLOW] + "low.core  # old\n"}, 1)
    expect("allow entry without reason", {**base, ALLOW: "low.variant\n"}, -1)
    expect("re-export with no package importer is not wiring",
           {**base, "high/user.mojo": "from low.core import X\n"}, 1)
    print(f"[{'PASS' if fails == 0 else 'FAIL'}] orphans selftest - {7 - fails} / 7 checks")
    return 1 if fails else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    problems, counts = check(ROOT, a.all)
    for p in problems:
        print("orphans:", p)
    print(
        f"orphans: {'PASS' if not problems else 'FAIL'} "
        f"(wired {counts['wired']}, leaf {counts['leaf']}, no importer {counts['none']}; {len(problems)} problems)"
    )
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
