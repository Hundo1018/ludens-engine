"""Check that the package/layer tables in the docs match scripts/arch_layers.toml (ROADMAP 17.87).

    pixi run layers-sync              # exit 1 on a mismatch
    python3 scripts/layers_sync.py --selftest

`arch_layers.toml` is the source. docs/ARCHITECTURE.md §1 has one row per
package (`| layer | `pkg` | owns | must not own |`); CLAUDE.md groups the
packages of a layer in one row (`| layer | `a` `b` | 負責 |`). The prose
columns are hand-written, so this tool checks the (layer, package) pairs and
leaves the prose alone.
"""

import argparse
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ROW = re.compile(r"^\|\s*(\d+)\s*\|\s*((?:`[a-z_0-9]+`\s*)+)\|")
NAME = re.compile(r"`([a-z_0-9]+)`")


def toml_pairs(path):
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    return {(pkg, int(layer)) for pkg, layer in data["layers"].items()}


def doc_pairs(text):
    pairs = set()
    for ln in text.splitlines():
        m = ROW.match(ln)
        if m:
            layer = int(m.group(1))
            pairs.update((p, layer) for p in NAME.findall(m.group(2)))
    return pairs


def compare(want, got, label):
    problems = []
    for pkg, layer in sorted(want - got):
        problems.append(f"{label}: missing or wrong layer for `{pkg}` (arch_layers.toml says layer {layer})")
    for pkg, layer in sorted(got - want):
        problems.append(f"{label}: `{pkg}` at layer {layer} is not in arch_layers.toml")
    return problems


def selftest():
    text = "| 2 | `a` `b` | x |\n| 3 | `c` | y |\n| Layer | Package |\n"
    assert doc_pairs(text) == {("a", 2), ("b", 2), ("c", 3)}, doc_pairs(text)
    assert compare({("a", 2)}, {("a", 2)}, "d") == []
    assert len(compare({("a", 2)}, {("a", 3)}, "d")) == 2
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    want = toml_pairs(ROOT / "scripts" / "arch_layers.toml")
    problems = []
    for rel in ("CLAUDE.md", "docs/ARCHITECTURE.md"):
        got = doc_pairs((ROOT / rel).read_text(encoding="utf-8"))
        problems += compare(want, got, rel)
    for p in problems:
        print(p, file=sys.stderr)
    if not problems:
        print(f"layers-sync: {len(want)} packages match in CLAUDE.md and docs/ARCHITECTURE.md")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
