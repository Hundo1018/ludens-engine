"""Count ROADMAP statuses from the 編號索引 and list the open entries.

    pixi run roadmap-status            # per-subsystem counts + open entries
    pixi run roadmap-status -- --open  # only the open entries, one per line
    python3 scripts/roadmap_status.py --selftest

The index table (`## 編號索引`) is the single source for statuses: one row per
entry, `| 編號 | 條目 | 子系統 | 狀態 |`, with ✅ 🔶 ⬜ ⏸ as the status column.
The subsystem summary table (`## 子系統`) is compared against it; any
difference is printed so the two can be reconciled by hand.
"""

import argparse
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATUSES = ("✅", "🔶", "⬜", "⏸", "不排")
ROW = re.compile(r"^\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$")


def _section(lines, title):
    start = next(i for i, ln in enumerate(lines) if ln.startswith(title))
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    return lines[start + 1 : end]


def parse(text):
    """Return (index rows, summary rows). Index rows: (id, title, subsystem, status)."""
    lines = text.splitlines()
    index, summary = [], []
    for ln in _section(lines, "## 編號索引"):
        m = ROW.match(ln)
        if m and m.group(1) not in ("編號", "---") and not m.group(1).startswith(":"):
            status = next((s for s in STATUSES if s in m.group(4)), "?")
            if status == "?" and "不排" in m.group(4):
                status = "不排"
            index.append((m.group(1), re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", m.group(2)), m.group(3), status))
    for ln in _section(lines, "## 子系統"):
        if not ln.startswith("|"):
            continue
        cells = [c.strip() for c in ln.strip().strip("|").split("|")]
        if cells[0] not in ("子系統", "---") and not cells[0].startswith(":") and len(cells) == 6:
            summary.append(cells)
    return index, summary


def report(index, summary, open_only):
    by_sub = defaultdict(Counter)
    for _, _, sub, status in index:
        by_sub[sub][status] += 1
    if open_only:
        for eid, title, sub, status in index:
            if status != "✅":
                print(f"{status} {eid}\t{title}\t{sub}")
        return
    print("subsystem | ✅ | 🔶 | ⬜ | ⏸+不排 | (index) vs (summary table)")
    for row in summary:
        sub = re.sub(r"\[([^]]*)\]\([^)]*\)", r"\1", row[0])
        got = by_sub.get(sub, Counter())
        mine = [got["✅"], got["🔶"], got["⬜"], got["⏸"] + got["不排"]]
        want = [int(w.replace("**", "").strip()) for w in row[2:]]
        ok = mine == want
        cells = " | ".join(str(n) for n in mine)
        print(f"{sub} | {cells} | {'match' if ok else 'DIFF: summary ' + ' '.join(str(w) for w in want)}")
    total = Counter(st for _, _, _, st in index)
    print("total |", " | ".join(str(total[s]) for s in STATUSES), f"| {len(index)} entries")


def selftest():
    sample = (
        "## 編號索引\n\n| 編號 | 條目 | 子系統 | 狀態 |\n|---|---|---|:-:|\n"
        "| 1.0 | [a](x.md) | S | ✅ |\n| 1.1 | b | S | 🔶 |\n| 1.2 | c | T | ⬜ |\n"
        "\n## 子系統\n\n| 子系統 | 範圍 | ✅ | 🔶 | ⬜ | ⏸ / 不排 |\n|---|---|--:|--:|--:|--:|\n"
        "| [S](#s) | r | 1 | 1 | 0 | 0 |\n| T | r | 0 | 0 | 1 | 0 |\n"
    )
    index, summary = parse(sample)
    assert [r[3] for r in index] == ["✅", "🔶", "⬜"], index
    assert parse(sample.replace("⬜ |", "不排 |"))[0][2][3] == "不排"
    assert index[0][1] == "a", index
    assert len(summary) == 2 and summary[0][2:] == ["1", "1", "0", "0"], summary
    print("selftest ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--open", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.selftest:
        selftest()
        return 0
    index, summary = parse((ROOT / "docs" / "ROADMAP.md").read_text(encoding="utf-8"))
    if not index:
        print("no index rows found", file=sys.stderr)
        return 1
    report(index, summary, args.open)
    return 0


if __name__ == "__main__":
    sys.exit(main())
