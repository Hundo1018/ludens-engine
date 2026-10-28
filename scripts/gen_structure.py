"""Generate docs/STRUCTURE.md from the architecture index (ROADMAP 17.87).

    pixi run structure              # rewrite docs/STRUCTURE.md
    pixi run structure -- --check   # exit 1 when the file is stale
    pixi run structure -- --stdout  # print instead of writing
    python3 scripts/gen_structure.py --selftest

The declarations come from `build/archindex.json`, which `tools/archindex.mojo`
builds from `mojo doc` (every struct, trait, function and alias with its
signature and trait conformances). This script only formats them: package
(layer order from scripts/arch_layers.toml) -> module -> declarations.

The output is deterministic and carries no line numbers, line counts or
timestamps, so an unrelated edit does not change it. Underscore-prefixed names
are package-private (CLAUDE.md) and are left out.
"""

import argparse
import json
import re
import subprocess
import sys
import tomllib
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INDEX = ROOT / "build" / "archindex.json"
LAYERS = ROOT / "scripts" / "arch_layers.toml"
OUT = ROOT / "docs" / "STRUCTURE.md"

# Conformances every struct gets from the compiler; listing them is noise.
BASE_TRAITS = {"AnyType", "Copyable", "Movable", "Deinitable", "Destructable", "ImplicitlyDestructible", "ImplicitlyCopyable"}

HEADER = """\
# Structure

Generated from `build/archindex.json` by `scripts/gen_structure.py`
(`pixi run structure`); do not edit by hand. The CI job and the `pre-push`
hook run `pixi run structure -- --check`.

Packages are in layer order (`scripts/arch_layers.toml`). For one name use
`pixi run arch -- def NAME`; for the import graph use `pixi run arch -- deps PKG`.
Underscore-prefixed names are package-private and are not listed. Methods are
counted, not listed.
"""


def refresh_index():
    """Make build/archindex.json current (arch.sh rebuilds it by mtime)."""
    subprocess.run(["bash", str(ROOT / "scripts" / "arch.sh"), "summary"], cwd=ROOT, check=True, stdout=subprocess.DEVNULL)


def load_layers():
    data = tomllib.loads(LAYERS.read_text(encoding="utf-8"))
    infra = data.get("infrastructure", {}).get("packages", [])
    order = sorted(data["layers"].items(), key=lambda kv: (kv[1], kv[0]))
    return [(p, str(layer)) for p, layer in order] + [(p, "infra") for p in infra]


def public(name):
    return not name.startswith("_")


def traits_of(decl):
    return [t for t in decl["traits_csv"].split(",") if t and t not in BASE_TRAITS]


def render(decls, packages):
    by_pkg = defaultdict(lambda: defaultdict(list))
    for d in decls:
        by_pkg[d["package"]][d["module"]].append(d)

    out = [HEADER.rstrip("\n")]
    for pkg, layer in packages:
        modules = by_pkg.get(pkg)
        if not modules:
            continue
        n_pub = sum(1 for ds in modules.values() for d in ds if d["kind"] != "method" and public(d["name"]))
        out.append(f"\n## {pkg} (layer {layer}) — {len(modules)} modules, {n_pub} public declarations")
        for mod in sorted(modules):
            ds = modules[mod]
            methods = defaultdict(int)
            for d in ds:
                if d["kind"] == "method" and public(d["name"]):
                    methods[d["parent"]] += 1
            structs = sorted((d for d in ds if d["kind"] == "struct" and public(d["name"])), key=lambda d: d["name"])
            tr = sorted((d for d in ds if d["kind"] == "trait" and public(d["name"])), key=lambda d: d["name"])
            funcs = sorted((d for d in ds if d["kind"] == "function" and public(d["name"])), key=lambda d: (d["name"], d["signature"]))
            aliases = sorted({d["name"] for d in ds if d["kind"] == "alias" and public(d["name"])})
            if not (structs or tr or funcs or aliases):
                continue
            out.append(f"\n### `{pkg}/{mod}.mojo`")
            for d in tr:
                out.append(f"- trait `{d['name']}` — {methods.get(d['name'], 0)} methods")
            for d in structs:
                conf = traits_of(d)
                tail = f" : {', '.join(conf)}" if conf else ""
                out.append(f"- struct `{d['name']}`{tail} — {methods.get(d['name'], 0)} methods")
            for d in funcs:
                out.append(f"- `{d['signature']}`")
            if aliases:
                out.append("- aliases: " + ", ".join(f"`{a}`" for a in aliases))
    return "\n".join(out).rstrip("\n") + "\n"


def build():
    refresh_index()
    decls = json.loads(INDEX.read_text(encoding="utf-8"))["decls"]
    return render(decls, load_layers())


def selftest():
    def d(kind, name, **kw):
        base = {"path": "p/m.mojo", "line": 1, "kind": kind, "name": name, "signature": f"{kind} {name}", "package": "p", "module": "m", "parent": "", "raises": False, "traits_csv": ""}
        base.update(kw)
        return base

    decls = [
        d("struct", "B", traits_csv="AnyType,Copyable,Shape"),
        d("method", "area", parent="B"),
        d("method", "_hidden", parent="B"),
        d("struct", "_Private"),
        d("function", "make", signature="def make() -> B"),
        d("function", "_helper"),
        d("alias", "Scalar"),
        d("trait", "Shape"),
    ]
    first = render(decls, [("p", "1")])
    assert render(list(reversed(decls)), [("p", "1")]) == first, "output must not depend on input order"
    assert "struct `B` : Shape — 1 methods" in first, first
    assert "_Private" not in first and "_helper" not in first and "_hidden" not in first, first
    assert "- trait `Shape` — 0 methods" in first and "`def make() -> B`" in first and "`Scalar`" in first, first
    assert re.search(r"## p \(layer 1\) — 1 modules, 4 public declarations", first), first
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    text = build()
    if args.stdout:
        sys.stdout.write(text)
        return 0
    if args.check:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print("docs/STRUCTURE.md is stale: run `pixi run structure` and commit it", file=sys.stderr)
            return 1
        print("structure: up to date")
        return 0
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUT.relative_to(ROOT)} ({text.count(chr(10))} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
