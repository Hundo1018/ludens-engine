"""The 5 x 7 dot font (ui/font.mojo): every character has dots and its own shape, text lays out 6 columns a character,
and draw_text emits exactly one square per lit dot. Standard library only. `pixi run -e wasm test-ui`."""
from ui.draw import Color, DrawList
from ui.font import GLYPH_H, GLYPH_W, draw_text, glyph_row, text_width

comptime SHOWN = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ.,:!?-+/%()[]=<>_'*# "


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label)


def dots(ch: String) -> Int:
    var n = 0
    for r in range(GLYPH_H):
        var bits = glyph_row(ch, r)
        for c in range(GLYPH_W):
            n += (bits >> c) & 1
    return n


def same(a: String, b: String) -> Bool:
    for r in range(GLYPH_H):
        if glyph_row(a, r) != glyph_row(b, r):
            return False
    return True


def picture(s: String) -> String:
    var out = String()
    for r in range(GLYPH_H):
        for k in range(s.byte_length()):
            var bits = glyph_row(String(s[byte=k]), r)
            for c in range(GLYPH_W):
                out += "#" if (bits >> (GLYPH_W - 1 - c)) & 1 == 1 else "."
            out += " "
        out += "\n"
    return out


def main() raises:
    var c = Check()
    var blank = 0
    var twins = 0
    var chars = List[String]()
    for k in range(SHOWN.byte_length()):
        chars.append(String(SHOWN[byte=k]))
    for i in range(len(chars)):
        if chars[i] != " " and dots(chars[i]) == 0:
            blank += 1
        for j in range(i + 1, len(chars)):
            if same(chars[i], chars[j]):
                twins += 1
                print("  twin glyphs:", chars[i], chars[j])
    c.ok(blank == 0, "every printable character in the set has dots")
    c.ok(twins == 0, "no two characters share a shape")
    c.ok(dots(" ") == 0, "a space is empty")
    c.ok(same("a", "A") and same("z", "Z"), "lowercase folds to uppercase")
    c.ok(dots("~") == 20 and same("~", "é"), "an unknown character is the 20-dot box")

    c.ok(text_width("", 3) == 0 and text_width("A", 3) == 15 and text_width("AB", 2) == 22, "width: 6 columns a character, minus the last gap")

    var dl = DrawList()
    draw_text(dl, 10, 20, "10", 2, Color.rgb(1, 1, 1))
    c.ok(dl.count() == dots("1") + dots("0"), "one square per lit dot (" + String(dl.count()) + ")")
    var dl2 = DrawList()
    draw_text(dl2, 10, 20, "10", 2, Color.rgb(1, 1, 1))
    c.ok(dl.hash() == dl2.hash(), "the same text gives the same draw list hash")
    var dl3 = DrawList()
    draw_text(dl3, 10, 20, "01", 2, Color.rgb(1, 1, 1))
    c.ok(dl.hash() != dl3.hash(), "different text gives a different hash")

    print(picture("SCORE 0123"))
    print(picture("TIME UP! A-Z"))
    print("ui_font:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_font: " + String(c.failed) + " checks failed")
