"""Extract the platform golden and the fp-probe dump from a CI portability job log.

    pixi run python -I scripts/ci_log_extract.py LOG --golden-out tests/golden/test_stdout.linux-aarch64.txt \
        --dump-out build/fp_dump_aarch64.json

LOG is the saved output of `mcp__github__get_job_logs` (a JSON object with a
`logs_content` string) or plain log text. The portability job prints the
platform golden between `----- BEGIN GOLDEN <path> -----` and
`----- END GOLDEN <path> -----`, and the fp probe dump between
`----- BEGIN FP DUMP -----` and `----- END FP DUMP -----` (ci.yml, portability).
Each log line carries a GitHub timestamp prefix, which is removed. Exits 1 if a
block is missing, so a truncated log (tail_lines too small) is reported, not
silently written.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

TS = re.compile(r"^\d{4}-\d{2}-\d{2}T[\d:.]+Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
GOLDEN_BEGIN = re.compile(r"^----- BEGIN GOLDEN (\S+) -----$")


def load_lines(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    try:
        obj = json.loads(raw)
        text = obj["logs_content"] if isinstance(obj, dict) else raw
    except (json.JSONDecodeError, KeyError, TypeError):
        text = raw
    out = []
    for line in text.split("\n"):
        line = ANSI.sub("", TS.sub("", line.rstrip("\r")))
        out.append(line)
    return out


def block(lines: list[str], begin: str, end: str) -> list[str] | None:
    try:
        i = lines.index(begin)
    except ValueError:
        return None
    for j in range(i + 1, len(lines)):
        if lines[j] == end:
            return lines[i + 1 : j]
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("log", type=Path)
    ap.add_argument("--golden-out", type=Path)
    ap.add_argument("--dump-out", type=Path)
    args = ap.parse_args()
    lines = load_lines(args.log)
    status = 0

    if args.golden_out is not None:
        m = next((GOLDEN_BEGIN.match(x) for x in lines if GOLDEN_BEGIN.match(x)), None)
        if m is None:
            print("golden: BEGIN marker not found (log truncated?)", file=sys.stderr)
            return 1
        body = block(lines, m.group(0), f"----- END GOLDEN {m.group(1)} -----")
        if body is None:
            print("golden: END marker not found", file=sys.stderr)
            return 1
        text = "\n".join(body) + "\n"
        args.golden_out.parent.mkdir(parents=True, exist_ok=True)
        args.golden_out.write_text(text, encoding="utf-8")
        print(f"golden {m.group(1)}: {len(body)} lines sha256={hashlib.sha256(text.encode()).hexdigest()[:16]}")

    if args.dump_out is not None:
        body = block(lines, "----- BEGIN FP DUMP -----", "----- END FP DUMP -----")
        if body is None:
            print("dump: markers not found", file=sys.stderr)
            return 1
        text = "\n".join(body).strip() + "\n"
        json.loads(text)  # the dump must be valid JSON
        args.dump_out.parent.mkdir(parents=True, exist_ok=True)
        args.dump_out.write_text(text, encoding="utf-8")
        print(f"dump: {len(text)} bytes -> {args.dump_out}")

    return status


if __name__ == "__main__":
    raise SystemExit(main())
