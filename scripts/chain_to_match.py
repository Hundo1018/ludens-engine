"""Rewrite `if x == A / elif x == B / else` chains into `match` (Mojo 1.2.0; issue #67).

    pixi run python3 scripts/chain_to_match.py              # list the chains
    pixi run python3 scripts/chain_to_match.py --apply      # rewrite them in place
    pixi run python3 scripts/chain_to_match.py --selftest

A chain is converted when
  * every arm tests the same left-hand side with `==`, the left-hand side has no
    call (so evaluating it once instead of per arm cannot change behaviour),
  * every right-hand side is an identifier, a dotted name or an integer literal,
  * there are at least three arms, or two arms and an `else`, and
  * no arm body contains a triple-quoted string (re-indenting would change it).
`if` becomes `match LHS:`, a literal arm becomes `case 3:`, a named arm becomes
`case == NAME:` (a bare `case NAME:` would bind a new variable and match
everything), `else:` becomes `case _:`. A `comptime if` chain becomes
`comptime match`. Run until stable: an inner chain is converted on the pass after
its outer chain.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKIP = {"build", "build64", ".pixi", ".git"}
LHS = r"[A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)*(?:\[[\w\.\+\- ]*\])?"
RHS = r"-?\d+|[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*"
TAIL = r":(?P<c>[ \t]*#.*)?\s*$"
HEAD = re.compile(rf"^(?P<ind> *)(?P<ct>comptime )?if (?P<lhs>{LHS}) == (?P<rhs>{RHS}){TAIL}")
ARM = re.compile(rf"^(?P<ind> *)elif (?P<lhs>{LHS}) == (?P<rhs>{RHS}){TAIL}")
ELSE = re.compile(rf"^(?P<ind> *)else{TAIL}")
CONT = re.compile(r"^ *(elif\b|else\b)")
INT = re.compile(r"^-?\d+$")


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def block_end(lines, start, ind):
    """Index after the body that begins at `start` (indented more than `ind`)."""
    j = start
    last = start
    while j < len(lines):
        if lines[j].strip() == "":
            j += 1
            continue
        if indent_of(lines[j]) <= ind:
            break
        j += 1
        last = j
    return last


def parse_chain(lines, i):
    """Return (arms, else_body_range, end) for the chain starting at line i, or None.

    arms: list of (rhs, body_start, body_end); else range is (start, end) or None.
    """
    m = HEAD.match(lines[i])
    if not m:
        return None
    ind = len(m.group("ind"))
    lhs = m.group("lhs")
    arms = []
    j = i
    cur = m
    while True:
        body_start = j + 1
        body_end = block_end(lines, body_start, ind)
        if body_end == body_start:
            return None
        arms.append((cur.group("rhs"), body_start, body_end, cur.group("c") or ""))
        j = body_end
        nxt = j
        while nxt < len(lines) and lines[nxt].strip() == "":
            nxt += 1
        if nxt >= len(lines) or indent_of(lines[nxt]) != ind:
            return arms, None, j, m
        am = ARM.match(lines[nxt])
        if am and am.group("lhs") == lhs:
            cur = am
            j = nxt
            continue
        em = ELSE.match(lines[nxt])
        if em:
            e_start = nxt + 1
            e_end = block_end(lines, e_start, ind)
            if e_end == e_start:
                return None
            return arms, (e_start, e_end, em.group("c") or ""), e_end, m
        if CONT.match(lines[nxt]):
            return None  # an elif/else this tool does not understand: leave the whole chain alone
        return arms, None, j, m


def convert_once(text):
    lines = text.split("\n")
    i = 0
    changed = 0
    out = []
    while i < len(lines):
        parsed = parse_chain(lines, i)
        if parsed:
            arms, els, end, m = parsed
            bodies = [lines[a:b] for _, a, b, _ in arms] + ([lines[els[0] : els[1]]] if els else [])
            ok = (len(arms) >= 3 or (len(arms) >= 2 and els)) and not any('"""' in ln for body in bodies for ln in body)
            if ok:
                ind = m.group("ind")
                kw = "comptime match" if m.group("ct") else "match"
                out.append(f"{ind}{kw} {m.group('lhs')}:")
                for (rhs, a, b, note) in arms:
                    pat = rhs if INT.match(rhs) else f"== {rhs}"
                    out.append(f"{ind}    case {pat}:{note}")
                    out.extend(("    " + ln) if ln.strip() else ln for ln in lines[a:b])
                if els:
                    out.append(f"{ind}    case _:{els[2]}")
                    out.extend(("    " + ln) if ln.strip() else ln for ln in lines[els[0] : els[1]])
                i = end
                changed += 1
                continue
        out.append(lines[i])
        i += 1
    return "\n".join(out), changed


def convert(text):
    total = 0
    while True:
        text, n = convert_once(text)
        if n == 0:
            return text, total
        total += n


def selftest():
    src = (
        "def f(k: Int) -> Int:\n"
        "    if k == A:\n        return 1\n    elif k == B:\n        return 2\n    elif k == 3:\n        return 3\n    else:\n        return 4\n"
    )
    want = (
        "def f(k: Int) -> Int:\n"
        "    match k:\n        case == A:\n            return 1\n        case == B:\n            return 2\n"
        "        case 3:\n            return 3\n        case _:\n            return 4\n"
    )
    assert convert(src) == (want, 1), convert(src)[0]
    two = "    if k == A:\n        x = 1\n    elif k == B:\n        x = 2\n"
    assert convert(two) == (two, 0), "two arms without else stay"
    assert convert("    if k == A:\n        x = 1\n    else:\n        x = 2\n")[1] == 0
    call = "    if f(k) == A:\n        x = 1\n    elif f(k) == B:\n        x = 2\n    else:\n        x = 3\n"
    assert convert(call)[1] == 0, "a call on the left-hand side is not hoisted"
    mixed = "    if k == A:\n        x = 1\n    elif j == B:\n        x = 2\n    else:\n        x = 3\n"
    assert convert(mixed)[1] == 0, "different left-hand sides"
    doc = '    if k == A:\n        s = """a\n   b"""\n    elif k == B:\n        x = 2\n    else:\n        x = 3\n'
    assert convert(doc)[1] == 0
    ct = "    comptime if k == A:\n        x = 1\n    elif k == B:\n        x = 2\n    else:\n        x = 3\n"
    assert convert(ct)[0].startswith("    comptime match k:\n        case == A:"), convert(ct)[0]
    nested = (
        "    if a == 1:\n        if b == X:\n            p = 1\n        elif b == Y:\n            p = 2\n        else:\n            p = 3\n"
        "    elif a == 2:\n        p = 4\n    else:\n        p = 5\n"
    )
    out, n = convert(nested)
    assert n == 2 and "match a:" in out and "match b:" in out and "            match b:" in out, out
    tail = "    if k == A:\n        x = 1\n    elif k == B:\n        x = 2\n    elif k == C:\n        x = 3\n    return x\n"
    out, n = convert(tail)
    assert n == 1 and out.endswith("            x = 3\n    return x\n"), out
    commented = "    comptime if k == A:\n        x = 1\n    elif k == B:\n        x = 2\n    else:  # last\n        x = 3\n"
    assert "case _:  # last" in convert(commented)[0], convert(commented)[0]
    odd = "    if k == A:\n        x = 1\n    elif k == B:\n        x = 2\n    elif k == C and j:\n        x = 3\n    else:\n        x = 4\n"
    assert convert(odd) == (odd, 0), "an unparsed elif must abort the whole chain, not split it"
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
    total = 0
    for p in sorted(ROOT.rglob("*.mojo")):
        rel = p.relative_to(ROOT)
        if SKIP & set(rel.parts) or (args.only and not any(o in rel.as_posix() for o in args.only)):
            continue
        text = p.read_text(encoding="utf-8")
        new, n = convert(text)
        if n:
            print(f"{rel.as_posix()}: {n}")
            total += n
            if args.apply:
                p.write_text(new, encoding="utf-8")
    print(f"{total} chains" + (" rewritten" if args.apply else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
