"""The ui/text.mojo checks: UTF-8 decoding and line breaking with CJK rules (ludens-engine #17). Standard library only.

The metrics are fixed-width: 10 for everything narrow, 20 for the wide ranges. Expected lines are worked out by hand
in the comments; the last case is a property test over generated text.

Build and run: `pixi run -e wasm test-ui`."""
from ui.text import (
    GlyphMetrics,
    Line,
    break_lines,
    decode_utf8,
    is_wide,
    measure,
    never_ends_line,
    never_starts_line,
)


struct Fixed(GlyphMetrics):
    def __init__(out self):
        pass

    def advance(self, cp: Int) -> Float32:
        return Float32(20) if is_wide(cp) else Float32(10)


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

    def lines(mut self, text: String, want: List[String], max_width: Float32, label: String):
        var got = break_lines(text, Fixed(), max_width)
        var ok = len(got) == len(want)
        var shown = String()
        for i in range(len(got)):
            var piece = String(text[byte = got[i].start : got[i].end])
            shown += "[" + piece + "]"
            if ok and piece != want[i]:
                ok = False
        if not ok:
            var wanted = String()
            for i in range(len(want)):
                wanted += "[" + want[i] + "]"
            self.ok(False, label + ": got " + shown + " want " + wanted)
        else:
            self.passed += 1


def L(*parts: String) -> List[String]:
    var out = List[String]()
    for p in parts:
        out.append(p)
    return out^


struct Lcg:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def below(mut self, n: Int) -> Int:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return Int((self.s >> 33) % UInt64(n))


def main() raises:
    var c = Check()

    # --- decoding
    var d = decode_utf8("aé你😀")
    c.ok(len(d) == 4, "decode: four code points")
    c.ok(d[0].value == 0x61 and d[1].value == 0xE9 and d[2].value == 0x4F60 and d[3].value == 0x1F600, "decode: values")
    c.ok(d[1].end - d[1].start == 2 and d[2].end - d[2].start == 3 and d[3].end - d[3].start == 4, "decode: byte lengths 2, 3, 4")
    c.ok(d[3].end == "aé你😀".byte_length(), "decode: the last range ends at the end of the string")
    c.ok(is_wide(0x4F60) and is_wide(0x3042) and is_wide(0xAC00) and is_wide(0xFF0C) and not is_wide(0x61) and not is_wide(0xE9), "wide classes")

    # --- wrapping, worked out by hand (narrow = 10, wide = 20)
    c.lines("hello world foo", L("hello", "world", "foo"), 60, "words wrap at spaces")
    c.lines("你好世界，再見。", L("你好世", "界，再", "見。"), 60, "CJK breaks between characters")
    c.lines("你好世，", L("你好", "世，"), 60, "a closing mark never starts a line: it takes the character before it along")
    c.lines("你好「世界", L("你好", "「世界"), 60, "an opening mark never ends a line")
    c.lines("abcdefghijklmnop", L("abcdef", "ghijkl", "mnop"), 60, "a word wider than the line breaks inside")
    c.lines("ab   cd", L("ab", "cd"), 20, "spaces hang off the end and are not carried to the next line")
    c.lines("你", L("你"), 10, "a character wider than the line stays alone")
    c.lines("你好", L("你", "好"), 10, "...and the next one goes below")
    c.lines("a\nb", L("a", "b"), 100, "newline")
    c.lines("a\n\nb", L("a", "", "b"), 100, "an empty line is kept")
    c.lines("a\n", L("a", ""), 100, "a trailing newline gives an empty last line")
    c.lines("", L(""), 100, "the empty text is one empty line")
    c.lines("Hello 世界 world", L("Hello 世界", "world"), 100, "latin and CJK mix: 50 + 10 + 20 + 20 fills the line exactly")
    c.lines("Hello 世界 world", L("Hello 世", "界 world"), 90, "...and at 90 the break falls between the two CJK characters")
    c.ok(measure("ab你", Fixed()) == 40, "measure: 10 + 10 + 20")
    c.ok(measure("a\nb", Fixed()) == 20, "measure: a newline is zero wide")
    var one = break_lines("hello world", Fixed(), 60)
    c.ok(one[0].width == 50 and one[1].width == 50, "line widths exclude hanging spaces")

    # --- property test over generated text
    var rng = Lcg(7)
    var pool = List[String]()
    for s in ["a", "b", "c", "x", " ", " ", "你", "好", "世", "界", "，", "。", "「", "」", "\n", "é", "😀"]:
        pool.append(String(s))
    var lost = 0
    var too_wide = 0
    var cases = 0
    for _ in range(300):
        var text = String()
        for _ in range(1 + rng.below(40)):
            text += pool[rng.below(len(pool))]
        var max_width = Float32(20 + rng.below(8) * 10)
        var lines = break_lines(text, Fixed(), max_width)
        cases += 1
        # concatenating the lines gives back every non-space, non-newline character in order
        var rebuilt = String()
        for i in range(len(lines)):
            rebuilt += String(text[byte = lines[i].start : lines[i].end])
        var want = String()
        var cps = decode_utf8(text)
        var kept = String()
        for i in range(len(cps)):
            if cps[i].value != 0x20 and cps[i].value != 10:
                want += String(text[byte = cps[i].start : cps[i].end])
        for i in range(len(decode_utf8(rebuilt))):
            var r = decode_utf8(rebuilt)[i]
            if r.value != 0x20 and r.value != 10:
                kept += String(rebuilt[byte = r.start : r.end])
        if kept != want:
            lost += 1
        # a line wider than the limit is only allowed when it is one character
        for i in range(len(lines)):
            var chars = len(decode_utf8(String(text[byte = lines[i].start : lines[i].end])))
            if lines[i].width > max_width + 1e-3 and chars > 1:
                too_wide += 1
    c.ok(lost == 0, "300 generated texts: no character is lost, duplicated or reordered (" + String(lost) + " bad)")
    c.ok(too_wide == 0, "300 generated texts: every line fits unless it is a single character (" + String(too_wide) + " bad)")

    print("ui_text:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_text: " + String(c.failed) + " checks failed")
