"""String tables (ui/loc.mojo): fallback chain, a raw key is never returned and is counted, plural rules for four rule
families, run-time language switch, pseudo-localization, validation, and the glyph check against the font atlas.
Standard library only. `pixi run -e wasm test-ui`."""
from ui.loc import (
    CAT_FEW, CAT_MANY, CAT_ONE, CAT_OTHER, MISSING_TEXT, PLURAL_FR, PLURAL_ONE_OTHER, PLURAL_OTHER, PLURAL_SLAVIC,
    Localizer, StringTable, fmt, plural_category, pseudo_text,
)
from ui.sdf_font import SdfFont
from ui.text import decode_utf8


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


def sample() -> Localizer:
    var loc = Localizer()
    var en = StringTable("en", PLURAL_ONE_OTHER)
    en.add("hud.paused", "PAUSED", "Banner while the game is paused", 12)
    en.add("hud.hint", "WASD move, Space jump", "Controls hint at the bottom edge", 40)
    en.add("hud.score", "Score {0} of {1}", "{0} points so far, {1} points to win", 24)
    en.add_plural("hud.jumps", "{n} jumps", one="{n} jump", context="Jump counter; {n} is the count", max_len=16)
    en.add("menu.quit", "Quit", "Menu entry that closes the game", 8)
    var zh_tw = StringTable("zh-TW", PLURAL_OTHER, "en")
    zh_tw.add("hud.paused", "暫停", "", 12)
    zh_tw.add("hud.hint", "WASD 移動，空白鍵跳躍", "", 40)
    zh_tw.add("hud.score", "得分 {0} / {1}", "", 24)
    zh_tw.add_plural("hud.jumps", "跳躍 {n} 次", max_len=16)
    loc.add_table(en^)
    loc.add_table(zh_tw^)
    return loc^


def main() raises:
    var c = Check()
    var loc = sample()
    c.ok(loc.locale() == "en" and loc.get("hud.paused") == "PAUSED", "the source locale is current first")
    c.ok(loc.set_locale("zh-TW") and loc.get("hud.paused") == "暫停", "run-time switch to zh-TW")
    var v = loc.version
    c.ok(not loc.set_locale("fr") and loc.locale() == "zh-TW" and loc.version == v, "an unknown locale changes nothing")
    c.ok(loc.get("menu.quit") == "Quit" and loc.missing_keys == 0, "a key zh-TW lacks comes from its fallback (en), not as an error")
    var raw = loc.get("no.such.key")
    c.ok(raw != "no.such.key" and raw == MISSING_TEXT and loc.missing_keys == 1 and loc.last_missing == "no.such.key", "a missing key returns the placeholder, never the key, and counts 1 error")
    _ = loc.plural("no.such.plural", 3)
    _ = loc.format("no.such.format", List[String]())
    c.ok(loc.missing_keys == 3, "plural and format count missing keys too")
    loc.reset_errors()
    c.ok(loc.missing_keys == 0, "errors reset")

    var args = List[String]()
    args.append("12")
    args.append("30")
    c.ok(loc.format("hud.score", args) == "得分 12 / 30", "positional arguments, zh-TW")
    _ = loc.set_locale("en")
    c.ok(loc.format("hud.score", args) == "Score 12 of 30", "positional arguments, en")
    c.ok(fmt("{1}{0}{2}", args) == "3012{2}", "a placeholder without an argument is kept")

    c.ok(loc.plural("hud.jumps", 1) == "1 jump" and loc.plural("hud.jumps", 0) == "0 jumps" and loc.plural("hud.jumps", 2) == "2 jumps", "English: 1 jump, 0 jumps, 2 jumps")
    _ = loc.set_locale("zh-TW")
    c.ok(loc.plural("hud.jumps", 1) == "跳躍 1 次" and loc.plural("hud.jumps", 7) == "跳躍 7 次", "Chinese has one form")

    c.ok(plural_category(PLURAL_ONE_OTHER, 1) == CAT_ONE and plural_category(PLURAL_ONE_OTHER, 2) == CAT_OTHER, "one-other rule")
    c.ok(plural_category(PLURAL_FR, 0) == CAT_ONE and plural_category(PLURAL_FR, 1) == CAT_ONE and plural_category(PLURAL_FR, 2) == CAT_OTHER, "French: 0 and 1 are one")
    c.ok(plural_category(PLURAL_OTHER, 1) == CAT_OTHER and plural_category(PLURAL_OTHER, 100) == CAT_OTHER, "other-only rule")
    var ru_ok = True
    var one = [1, 21, 101]
    var few = [2, 3, 4, 22, 24, 102]
    var many = [0, 5, 9, 10, 11, 12, 14, 19, 20, 25, 111, 112]
    for n in one:
        ru_ok = ru_ok and plural_category(PLURAL_SLAVIC, n) == CAT_ONE
    for n in few:
        ru_ok = ru_ok and plural_category(PLURAL_SLAVIC, n) == CAT_FEW
    for n in many:
        ru_ok = ru_ok and plural_category(PLURAL_SLAVIC, n) == CAT_MANY
    c.ok(ru_ok, "Russian: 1 21 101 one; 2 3 4 22 24 102 few; 0 5 9 10 11 12 14 19 20 25 111 112 many")
    var ru = Localizer()
    var rt = StringTable("ru", PLURAL_SLAVIC)
    rt.add_plural("hud.jumps", "{n} X", one="{n} A", few="{n} B", many="{n} C", context="c", max_len=9)
    ru.add_table(rt^)
    c.ok(ru.plural("hud.jumps", 21) == "21 A" and ru.plural("hud.jumps", 3) == "3 B" and ru.plural("hud.jumps", 11) == "11 C", "a table's plural forms are chosen by its rule")

    # pseudo-localization
    _ = loc.set_locale("en")
    loc.set_pseudo(True)
    var p = loc.get("hud.hint")
    var plain = String("WASD move, Space jump")
    var np = len(decode_utf8(p))
    var nq = len(decode_utf8(plain))
    print("  pseudo:", p, "(", nq, "->", np, "code points)")
    c.ok(p != plain and np >= nq + nq * 4 // 10, "pseudo text differs and is at least 40 % longer")
    c.ok(pseudo_text("{n} jumps") == "[{n} jümps~~~~]", "placeholders are not accented: " + pseudo_text("{n} jumps"))
    c.ok(loc.plural("hud.jumps", 3).find("3") >= 0, "pseudo-localized plural still carries its number")
    loc.set_pseudo(False)
    c.ok(loc.get("hud.hint") == plain, "pseudo-localization off restores the text")

    # validation
    c.ok(len(loc.validate()) == 0, "the sample table validates (" + String(len(loc.validate())) + " problems)")
    c.ok(len(loc.untranslated("zh-TW")) == 1 and loc.untranslated("zh-TW")[0] == "menu.quit", "zh-TW lacks only menu.quit")
    var bad = Localizer()
    var bt = StringTable("en", PLURAL_ONE_OTHER)
    bt.add("Hud.Bad", "x", "ctx", 5)
    bt.add("hud.nocontext", "x", "", 5)
    bt.add("hud.nolimit", "x", "ctx", 0)
    bt.add("hud.long", "this is much too long", "ctx", 5)
    bt.add("single", "x", "ctx", 5)
    bad.add_table(bt^)
    var problems = bad.validate()
    for i in range(len(problems)):
        print("  validate:", problems[i])
    c.ok(len(problems) == 5, "five seeded problems found (" + String(len(problems)) + ")")

    # glyph check against the committed atlas
    var font: SdfFont
    with open("assets/fonts/NotoSansTC-Regular-24.lfont", "r") as f:
        font = SdfFont(f.read_bytes())
    c.ok(len(loc.missing_glyphs(font)) == 0, "every glyph of every text, plural form and pseudo text is in the atlas")
    var t2 = StringTable("ja", PLURAL_OTHER, "en")
    t2.add("hud.paused", "一時停止ꙮ", "", 12)
    loc.add_table(t2^)
    var gone = loc.missing_glyphs(font)
    c.ok(len(gone) == 1 and gone[0] == 0xA66E, "a character the atlas lacks (U+A66E) is reported")

    print("ui_loc:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_loc: " + String(c.failed) + " checks failed")
