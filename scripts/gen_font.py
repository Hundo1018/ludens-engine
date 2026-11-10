#!/usr/bin/env python3
"""Generate ui/font.mojo from the glyph art below (5 x 7 dots per character, '#' is a lit dot).

Run: pixi run -e wasm python3 scripts/gen_font.py [--check]   (--check fails if ui/font.mojo is out of date)"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "ui/font.mojo"

ART = {
    " ": [".....", ".....", ".....", ".....", ".....", ".....", "....."],
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "##.##", "#...#"],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    ",": [".....", ".....", ".....", ".....", ".##..", "..#..", ".#..."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
    "%": ["##..#", "##..#", "...#.", "..#..", ".#...", "#..##", "#..##"],
    "(": ["...#.", "..#..", ".#...", ".#...", ".#...", "..#..", "...#."],
    ")": [".#...", "..#..", "...#.", "...#.", "...#.", "..#..", ".#..."],
    "[": [".###.", ".#...", ".#...", ".#...", ".#...", ".#...", ".###."],
    "]": [".###.", "...#.", "...#.", "...#.", "...#.", "...#.", ".###."],
    "=": [".....", ".....", "#####", ".....", "#####", ".....", "....."],
    "<": ["...#.", "..#..", ".#...", "#....", ".#...", "..#..", "...#."],
    ">": [".#...", "..#..", "...#.", "....#", "...#.", "..#..", ".#..."],
    "_": [".....", ".....", ".....", ".....", ".....", ".....", "#####"],
    "'": ["..#..", "..#..", ".#...", ".....", ".....", ".....", "....."],
    "*": [".....", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "....."],
    "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
}
UNKNOWN = ["#####", "#...#", "#...#", "#...#", "#...#", "#...#", "#####"]


def rows(art: list[str]) -> list[int]:
    assert len(art) == 7 and all(len(r) == 5 for r in art), art
    return [int("".join("1" if c == "#" else "0" for c in r), 2) for r in art]


def source() -> str:
    chars = "".join(sorted(ART))
    flat = [v for ch in chars for v in rows(ART[ch])] 
    body = "".join(chr(48 + v) for v in flat)
    unk = "".join(chr(48 + v) for v in rows(UNKNOWN))
    lines = [
        '"""A 5 x 7 dot font for HUD text, no font file and no atlas: every lit dot is one `DrawList.fill` square.',
        "",
        "Generated by scripts/gen_font.py from its glyph art; do not edit by hand. Digits, A-Z (lowercase folds to uppercase)",
        "and . , : ! ? - + / % ( ) [ ] = < > _ ' * #. Any other character draws as a box. Standard library only.\"\"\"",
        "from ui.draw import Color, DrawList",
        "from ui.geom import Rect",
        "",
        "comptime GLYPH_W = 5",
        "comptime GLYPH_H = 7",
        f'comptime _CHARS = "{chars}"',
        "# seven rows per character, in _CHARS order, one ASCII character per row: its value plus 48. The low 5 bits are the dots, bit 4 the leftmost.",
        "# A string, not an InlineArray: Mojo 1.2.0 has no importable InlineArray (std.collections, std.memory and std.utils were tried).",
        f'comptime _ROWS = "{body}"',
        f'comptime _UNKNOWN = "{unk}"',
        "",
        "",
        "def glyph_row(ch: String, row: Int) -> Int:",
        '    """The 5 dots of one row (0 = top) of `ch` as a bit mask; bit 4 is the leftmost dot."""',
        "    var up = ch.upper()",
        "    var i = String(_CHARS).find(up)",
        "    if up.byte_length() != 1 or i < 0:",
        "        return Int(_UNKNOWN.unsafe_ptr()[row]) - 48",
        "    return Int(_ROWS.unsafe_ptr()[i * 7 + row]) - 48",
        "",
        "",
        "def text_width(s: String, scale: Float32) -> Float32:",
        '    """Pixels wide: 6 columns per character (5 dots and a gap), the last gap not counted."""',
        "    var n = s.byte_length()",
        "    if n == 0:",
        "        return 0",
        "    return Float32(n * 6 - 1) * scale",
        "",
        "",
        "def draw_text(mut dl: DrawList, x: Float32, y: Float32, s: String, scale: Float32, c: Color):",
        '    """Draw `s` with its top-left at (x, y); each dot is a `scale` x `scale` square."""',
        "    var cx = x",
        "    for k in range(s.byte_length()):",
        "        var ch = String(s[byte=k])",
        "        for r in range(GLYPH_H):",
        "            var bits = glyph_row(ch, r)",
        "            for col in range(GLYPH_W):",
        "                if (bits >> (GLYPH_W - 1 - col)) & 1 == 1:",
        "                    dl.fill(Rect(cx + Float32(col) * scale, y + Float32(r) * scale, scale, scale), c)",
        "        cx += 6 * scale",
        "",
    ]
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    src = source()
    if "--check" in argv:
        ok = OUT.exists() and OUT.read_text() == src
        print("font:", "up to date" if ok else "STALE: run scripts/gen_font.py")
        return 0 if ok else 1
    OUT.write_text(src)
    print(f"wrote {OUT.relative_to(ROOT)}: {len(ART)} glyphs")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
