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


def copyright_line() -> str:
    """The copyright notice recorded in README.md."""
    m = re.search(r'Copyright \(from the font\'s name table\): "([^"]+)"', (DIR / "README.md").read_text(encoding="utf-8"))
    if not m:
        raise SystemExit("check_font_asset: README.md has no copyright line")
    return m.group(1)


def write_built_license(out: Path) -> None:
    """Write `font-LICENSE.txt` beside the built font: the copyright notice, then the OFL text."""
    ofl = (DIR / "OFL.txt").read_text(encoding="utf-8")
    (out / "font-LICENSE.txt").write_text(f"Noto Sans TC (font.lfont is derived from it)\n{copyright_line()}\n\n{ofl}", encoding="utf-8")


def check_built(out: Path) -> list[str]:
    """Problems with the font in a built site: it has `font.lfont`, so it must carry the copyright and the license text."""
    if not (out / "font.lfont").is_file():
        return []
    lic = out / "font-LICENSE.txt"
    if not lic.is_file():
        return ["font.lfont is built without font-LICENSE.txt"]
    text = lic.read_text(encoding="utf-8")
    return [f"font-LICENSE.txt lacks {what!r}" for what in (copyright_line(), "SIL OPEN FONT LICENSE") if what not in text]


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "--built":
        problems = check_built(Path(sys.argv[2]))
        print("check_font_asset --built:", "; ".join(problems) if problems else "ok")
        return 1 if problems else 0
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
