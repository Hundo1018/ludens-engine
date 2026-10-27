"""Insert or replace a text block in docs/ROADMAP.md after an anchor line.

    pixi run python scripts/roadmap_note.py --anchor "#### 17.58 體積軟體" --text-file note.md
    pixi run python scripts/roadmap_note.py --anchor "..." --text-file note.md --replace-until "\\n---\\n"

The anchor must occur exactly once. --text-file is the block inserted directly
after the anchor line. With --replace-until, the text from the anchor up to
(not including) the first match of that regex after it is replaced instead.
Prints the line number of the change. Used for ROADMAP progress notes so the
same edit rules apply every time (ROADMAP.md is the only file touched).
"""

import argparse
import re
import sys
from pathlib import Path

ROADMAP = Path(__file__).resolve().parent.parent / "docs" / "ROADMAP.md"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--anchor", required=True)
    ap.add_argument("--text-file", required=True, type=Path)
    ap.add_argument("--replace-until", default=None)
    args = ap.parse_args()

    src = ROADMAP.read_text(encoding="utf-8")
    text = args.text_file.read_text(encoding="utf-8")
    if src.count(args.anchor) != 1:
        print(f"anchor must occur once, found {src.count(args.anchor)}", file=sys.stderr)
        return 1
    start = src.index(args.anchor)
    line_end = src.index("\n", start) + 1
    if args.replace_until is None:
        out = src[:line_end] + text + src[line_end:]
    else:
        m = re.compile(args.replace_until).search(src, line_end)
        if not m:
            print("replace-until pattern not found after anchor", file=sys.stderr)
            return 1
        out = src[:line_end] + text + src[m.start():]
    ROADMAP.write_text(out, encoding="utf-8")
    print("line", src[:start].count("\n") + 1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
