"""List (or rewrite) hand-written zero-argument `__init__` that Mojo 1.2.0 synthesizes (issue #67).

    pixi run python3 scripts/defaultable_scan.py              # list candidates
    pixi run python3 scripts/defaultable_scan.py --apply      # delete the redundant initializers
    pixi run python3 scripts/defaultable_scan.py --selftest

Mojo 1.2.0 gives every `Defaultable` struct a default `__init__()` that
default-constructs each field, provided the struct does not declare one. A
hand-written `def __init__(out self)` is therefore redundant when
  * the struct conforms to `Defaultable` (directly or through a trait that
    inherits it), and
  * the initializer only assigns `self.<field> = <default>` and assigns every
    declared field, where <default> is the zero value of a builtin scalar
    (0, 0.0, False, "") or a no-argument call of the field's own type.
Anything else (a non-zero value, a computed field, an argument-taking call)
changes behaviour when deleted and is left alone.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"build", "build64", ".pixi", ".git"}
INT_TYPES = {"Int", "UInt", "Int8", "Int16", "Int32", "Int64", "UInt8", "UInt16", "UInt32", "UInt64"}
FLOAT_TYPES = {"Float16", "Float32", "Float64", "BFloat16"}

STRUCT = re.compile(r"^(\s*)struct\s+(\w+)\s*(\[[^\]]*\])?\s*\(([^)]*)\)\s*:\s*$")
TRAIT = re.compile(r"^\s*trait\s+(\w+)\s*(?:\(([^)]*)\))?\s*:")
FIELD = re.compile(r"^\s{4}var\s+(\w+)\s*:\s*(.+?)\s*$")
ASSIGN = re.compile(r"^\s*self\.(\w+)\s*=\s*(.+?)\s*$")


def mojo_files():
    for p in sorted(ROOT.rglob("*.mojo")):
        if not SKIP & set(p.relative_to(ROOT).parts):
            yield p


def defaultable_traits(files):
    """Trait names that are, or inherit, Defaultable."""
    parents = {}
    for text in files.values():
        for ln in text.splitlines():
            m = TRAIT.match(ln)
            if m:
                parents[m.group(1)] = [t.strip() for t in (m.group(2) or "").split(",") if t.strip()]
    found = {"Defaultable"}
    changed = True
    while changed:
        changed = False
        for name, ps in parents.items():
            if name not in found and any(p.split("[")[0] in found for p in ps):
                found.add(name)
                changed = True
    return found


def is_default_value(value, ftype):
    t = ftype.strip()
    v = value.strip()
    if t in INT_TYPES and v == "0":
        return True
    if t in FLOAT_TYPES and v in ("0", "0.0"):
        return True
    if t == "Bool" and v == "False":
        return True
    if t == "String" and v in ('""', "String()"):
        return True
    return v == f"{t}()"


def find_candidates(text, traits):
    """Yield (struct name, init start line, init end line) for each redundant initializer."""
    lines = text.splitlines()
    out = []
    i = 0
    while i < len(lines):
        m = STRUCT.match(lines[i])
        if not m or m.group(1) != "":
            i += 1
            continue
        name = m.group(2)
        conf = [c.strip().split("[")[0] for c in m.group(4).split(",") if c.strip()]
        j = i + 1
        while j < len(lines) and (lines[j].startswith(" ") or not lines[j].strip()):
            j += 1
        body = range(i + 1, j)
        fields = {}
        for k in body:
            fm = FIELD.match(lines[k])
            if fm:
                fields[fm.group(1)] = fm.group(2)
        inits = [k for k in body if lines[k].strip() == "def __init__(out self):" and lines[k].startswith("    def")]
        i = j
        if not inits or not (set(conf) & traits) or not fields:
            continue
        start = inits[0]
        end = start + 1
        while end < j and (lines[end].startswith("        ") or not lines[end].strip()):
            end += 1
        assigned = {}
        ok = True
        in_doc = False
        for k in range(start + 1, end):
            s = lines[k].strip()
            if not s:
                continue
            if s.startswith('"""'):
                if not (s.endswith('"""') and len(s) > 3):
                    in_doc = not in_doc
                continue
            if in_doc:
                if s.endswith('"""'):
                    in_doc = False
                continue
            am = ASSIGN.match(lines[k])
            if not am or am.group(1) not in fields or not is_default_value(am.group(2), fields[am.group(1)]):
                ok = False
                break
            assigned[am.group(1)] = am.group(2)
        if ok and set(assigned) == set(fields):
            while end > start and not lines[end - 1].strip():
                end -= 1
            out.append((name, start, end))
    return out


def remove_ranges(text, ranges):
    lines = text.splitlines(keepends=True)
    for start, end in sorted(ranges, reverse=True):
        stop = end
        while stop < len(lines) and not lines[stop].strip():
            stop += 1
        del lines[start:stop]
        if start > 0 and start < len(lines) and not lines[start - 1].strip() and not lines[start].strip():
            del lines[start]
    return "".join(lines)


def selftest():
    traits = {"Defaultable"}
    good = (
        "struct A(Defaultable, Copyable):\n    var n: Int\n    var xs: List[Int]\n    var f: Float64\n\n"
        "    def __init__(out self):\n        self.n = 0\n        self.xs = List[Int]()\n        self.f = 0.0\n\n"
        "    def other(self) -> Int:\n        return self.n\n"
    )
    assert [c[0] for c in find_candidates(good, traits)] == ["A"]
    assert find_candidates(good.replace("self.n = 0", "self.n = 4"), traits) == []
    assert find_candidates(good.replace("Defaultable, ", ""), traits) == []
    assert find_candidates(good.replace("        self.f = 0.0\n", ""), traits) == [], "a field left unassigned"
    assert find_candidates(good.replace("List[Int]()", "List[Int](capacity=4)"), traits) == []
    cut = remove_ranges(good, [(c[1], c[2]) for c in find_candidates(good, traits)])
    assert "__init__" not in cut and "def other" in cut and "var f: Float64\n\n    def other" in cut, cut
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--only", action="append", default=[], help="restrict to a path substring (repeatable)")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    files = {p: p.read_text(encoding="utf-8") for p in mojo_files()}
    traits = defaultable_traits(files)
    total = 0
    for p, text in files.items():
        rel = p.relative_to(ROOT).as_posix()
        if args.only and not any(o in rel for o in args.only):
            continue
        cands = find_candidates(text, traits)
        for name, start, _ in cands:
            print(f"{rel}:{start + 1}: struct {name}")
        total += len(cands)
        if args.apply and cands:
            p.write_text(remove_ranges(text, [(c[1], c[2]) for c in cands]), encoding="utf-8")
    print(f"{total} redundant zero-argument initializers" + (" removed" if args.apply else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
