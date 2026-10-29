"""Remove the `^` that Mojo 1.2.0 reports as a no-op transfer (issue #67).

    pixi run python3 scripts/fix_noop_transfers.py build/agent_gate.log [--apply]
    pixi run python3 scripts/fix_noop_transfers.py --selftest

The compiler prints `FILE:LINE:COL: warning: this value is borrowed here, so the
transfer has no effect and can be removed`; COL is the column of the `^`. Every
position found in the log is checked to hold a `^` before it is removed, so a log
from an older tree cannot delete the wrong character.
"""
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WARN = re.compile(r"^(\S+\.mojo):(\d+):(\d+): warning: this value is borrowed here, so the transfer has no effect")


def positions(text):
    found = defaultdict(set)
    for ln in text.splitlines():
        m = WARN.match(ln)
        if m:
            path = Path(m.group(1))
            if path.is_absolute():
                try:
                    path = path.relative_to(ROOT)
                except ValueError:
                    continue
            found[path].add((int(m.group(2)), int(m.group(3))))
    return found


def strip(source, spots):
    """Delete the `^` at each (line, col); returns (new text, number removed, spots that held no caret)."""
    lines = source.split("\n")
    removed, bad = 0, []
    for line, col in sorted(spots, reverse=True):
        s = lines[line - 1]
        if col - 1 < len(s) and s[col - 1] == "^":
            lines[line - 1] = s[: col - 1] + s[col:]
            removed += 1
        else:
            bad.append((line, col))
    return "\n".join(lines), removed, bad


def selftest():
    src = "a = f(x^, y^)\nb = g(z^)\n"
    spots = {(1, 8), (1, 12), (2, 8)}
    out, n, bad = strip(src, spots)
    assert (out, n, bad) == ("a = f(x, y)\nb = g(z)\n", 3, []), (out, n, bad)
    assert strip("a = 1\n", {(1, 3)})[2] == [(1, 3)], "a position without ^ is reported, not deleted"
    log = f"{ROOT}/tests/t.mojo:3:9: warning: this value is borrowed here, so the transfer has no effect and can be removed\n"
    assert positions(log) == {Path("tests/t.mojo"): {(3, 9)}}, positions(log)
    assert positions("unrelated line\n") == {}
    print("selftest ok")


def main():
    if "--selftest" in sys.argv:
        selftest()
        return 0
    log = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
    total = 0
    for path, spots in sorted(positions(log).items()):
        full = ROOT / path
        new, n, bad = strip(full.read_text(encoding="utf-8"), spots)
        print(f"{path}: {n} removed" + (f", {len(bad)} without a caret {bad}" if bad else ""))
        total += n
        if "--apply" in sys.argv and n:
            full.write_text(new, encoding="utf-8")
    print(f"{total} transfers" + (" removed" if "--apply" in sys.argv else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
