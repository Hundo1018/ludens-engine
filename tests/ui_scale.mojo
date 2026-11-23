"""UI scaling and safe area (ui/scale.mojo): factor from a reference resolution, text scale clamp, safe rectangle, and
the cache key. Standard library only. `pixi run -e wasm test-ui`."""
from ui.geom import Insets
from ui.scale import MAX_TEXT_SCALE, MIN_TEXT_SCALE, UiScale


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


def main() raises:
    var c = Check()
    var s = UiScale.reference(960, 540)
    c.ok(s.factor(960, 540) == 1 and s.factor(1920, 1080) == 2 and s.factor(480, 270) == 0.5, "factor is 1, 2 and 0.5 at 960x540, 1920x1080, 480x270")
    c.ok(s.factor(1920, 540) == 1 and s.factor(960, 1080) == 1, "the smaller axis decides: a wide or a tall window keeps the layout whole")
    c.ok(s.px(10, 1920, 1080) == 20, "a length of 10 reference px is 20 px at 1920x1080")
    c.ok(s.font_px(14, 960, 540) == 14 and s.font_px(14, 1920, 1080) == 28, "font 14 -> 14 px and 28 px")
    s.set_text_scale(2.0)
    c.ok(s.font_px(14, 960, 540) == 28 and s.px(14, 960, 540) == 14, "text scale 2 doubles fonts, not lengths")
    s.set_text_scale(5.0)
    c.ok(s.text_scale == MAX_TEXT_SCALE, "text scale is clamped to 2.0")
    s.set_text_scale(0.1)
    c.ok(s.text_scale == MIN_TEXT_SCALE, "text scale is clamped to 0.5")
    s.set_text_scale(1.0)
    s.insets = Insets(44, 0, 44, 21)
    var r = s.safe_rect(844, 390)
    c.ok(r.x == 44 and r.y == 0 and r.w == 756 and r.h == 369, "safe rectangle of an 844x390 phone with 44 / 0 / 44 / 21 insets")
    var k1 = s.key(844, 390)
    s.insets = Insets(44, 0, 44, 22)
    c.ok(k1 != s.key(844, 390), "the key changes with an inset")
    s.insets = Insets(44, 0, 44, 21)
    c.ok(k1 == s.key(844, 390), "and returns to the same value when it does")
    s.set_text_scale(1.5)
    c.ok(k1 != s.key(844, 390) and s.key(844, 390) != s.key(845, 390), "the key changes with the text scale and the size")
    print("ui_scale:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_scale: " + String(c.failed) + " checks failed")
