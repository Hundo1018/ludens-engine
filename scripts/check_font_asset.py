#!/usr/bin/env python3
"""Check the committed font assets (#116): every `.lfont` in assets/fonts/ is listed in assets/fonts/README.md with its
sha256, the hash matches the file, and the license text (OFL.txt) is next to it. Also parses each header.

    pixi run -e wasm test-font"""
import hashlib
import re
import struct
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent / "assets/fonts"


def main() -> int:
    readme = (DIR / "README.md").read_text(encoding="utf-8")
    problems = []
    if not (DIR / "OFL.txt").is_file() or "SIL OPEN FONT LICENSE" not in (DIR / "OFL.txt").read_text(encoding="utf-8"):
        problems.append("OFL.txt (the license text) is missing")
    fonts = sorted(DIR.glob("*.lfont"))
    if not fonts:
        problems.append("no .lfont in assets/fonts")
    for f in fonts:
        data = f.read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        if f.name not in readme:
            problems.append(f"{f.name} is not described in README.md")
        if sha not in readme:
            problems.append(f"{f.name}: sha256 {sha} is not the one recorded in README.md")
        if data[:4] != b"LFNT":
            problems.append(f"{f.name}: bad magic")
            continue
        _, aw, ah, n = struct.unpack_from("<IIII", data, 4)
        off = (48 + 20 * n + 15) // 16 * 16
        if len(data) != off + aw * ah:
            problems.append(f"{f.name}: size {len(data)} does not match its header ({off + aw * ah})")
        m = re.search(re.escape(f.name) + r".*?(\d+) glyphs", readme, re.S)
        if not m or int(m.group(1)) != n:
            problems.append(f"{f.name}: README says {m.group(1) if m else '?'} glyphs, the file has {n}")
        print(f"{f.name}: {n} glyphs, atlas {aw}x{ah}, {len(data)} bytes, sha256 {sha[:16]}...")
    for p in problems:
        print("  " + p)
    print("check_font_asset:", "FAIL" if problems else "ok")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
