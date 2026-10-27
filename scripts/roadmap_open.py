"""List each 🔶 row of the ROADMAP index with its open-work lines, untruncated.

Usage: python3 scripts/roadmap_open.py [--ids 13.5,17.57]
A row's section is the `#### <id> ` heading; its open-work lines are those
that mention a remaining-work marker. Read-only.
"""
import re
import sys

PATH = "docs/ROADMAP.md"
MARKERS = re.compile(r"仍未處理|剩餘|仍未閉合|未做|移至|移到|未完成|尚未")


def main() -> None:
    text = open(PATH, encoding="utf-8").read().splitlines()
    wanted = None
    if len(sys.argv) == 3 and sys.argv[1] == "--ids":
        wanted = set(sys.argv[2].split(","))
    rows = []
    for line in text:
        m = re.match(r"\| (\d+\.\d+[a-z]?) \| .*\| 🔶 \|", line)
        if m and (wanted is None or m.group(1) in wanted):
            rows.append(m.group(1))
    for rid in rows:
        start = next((i for i, l in enumerate(text) if l.startswith(f"#### {rid} ")), None)
        print(f"=== {rid}  section: {'found' if start is not None else 'MISSING'}")
        if start is None:
            continue
        end = start + 1
        while end < len(text) and not text[end].startswith(("#### ", "## ")):
            end += 1
        for l in text[start:end]:
            if MARKERS.search(l):
                print("  " + l)
    print(f"total 🔶 rows: {len(rows)}")


if __name__ == "__main__":
    main()
