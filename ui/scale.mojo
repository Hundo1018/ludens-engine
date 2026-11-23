"""UI scaling and safe area (ludens-engine #116).

A layout is written once against a reference resolution (`ref_w` x `ref_h`, for example 960 x 540). `UiScale.factor` is
the uniform scale that makes the reference rectangle fit the window (`min(width / ref_w, height / ref_h)`), so the same
layout works at 640 x 360 and at 2560 x 1440. Text has a second, user-set multiplier, `text_scale`, from 0.5 to 2.0
(accessibility, #118): it changes font sizes only, not rectangles, so the layout has to wrap or grow to hold the larger
text (`SdfFont.wrap` and `SdfFont.text_height` give the size a wrapped string needs).

The safe area is a set of insets in window pixels that the shell reports (a notch, rounded corners, system bars:
`env(safe-area-inset-*)` on the web). `safe_rect` is the window minus those insets; HUD elements anchor to it.

Standard library only."""
from ui.geom import Insets, Rect

comptime MIN_TEXT_SCALE = Float32(0.5)
comptime MAX_TEXT_SCALE = Float32(2.0)


@fieldwise_init
struct UiScale(Copyable, ImplicitlyCopyable, Movable):
    var ref_w: Float32
    var ref_h: Float32
    var text_scale: Float32
    var insets: Insets  # window pixels

    @staticmethod
    def reference(ref_w: Float32, ref_h: Float32) -> Self:
        return Self(ref_w, ref_h, 1.0, Insets.none())

    def set_text_scale(mut self, s: Float32):
        """Clamped to 0.5 .. 2.0."""
        self.text_scale = MIN_TEXT_SCALE if s < MIN_TEXT_SCALE else (MAX_TEXT_SCALE if s > MAX_TEXT_SCALE else s)

    def factor(self, width: Float32, height: Float32) -> Float32:
        """Window pixels per reference pixel."""
        var fx = width / self.ref_w
        var fy = height / self.ref_h
        return fx if fx < fy else fy

    def safe_rect(self, width: Float32, height: Float32) -> Rect:
        """The window minus the safe-area insets, in window pixels."""
        return Rect(0, 0, width, height).inset(self.insets)

    def px(self, v: Float32, width: Float32, height: Float32) -> Float32:
        """A length in reference pixels as window pixels."""
        return v * self.factor(width, height)

    def font_px(self, base: Float32, width: Float32, height: Float32) -> Float32:
        """A font size in reference pixels as window pixels: layout factor times the user's text scale."""
        return base * self.factor(width, height) * self.text_scale

    def key(self, width: Float32, height: Float32) -> UInt64:
        """A value that changes whenever anything `px` / `font_px` / `safe_rect` read changes (for a HUD cache key)."""
        var h = UInt64(0xCBF29CE484222325)
        h = (h ^ UInt64(width.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(height.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.text_scale.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.left.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.top.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.right.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.bottom.to_bits())) * UInt64(0x100000001B3)
        return h


@fieldwise_init
struct UiEnv(Copyable, ImplicitlyCopyable, Movable):
    """What the host tells a game about the screen and the player's settings (`GameMode.set_ui_env`): the safe-area
    insets in window pixels, the text scale, the index of the locale the player picked in the game's own table list, and
    pseudo-localization."""
    var text_scale: Float32
    var insets: Insets
    var locale: Int
    var pseudo: Bool

    @staticmethod
    def default() -> Self:
        return Self(1.0, Insets.none(), 0, False)

    def key(self) -> UInt64:
        var h = UInt64(0xCBF29CE484222325)
        h = (h ^ UInt64(self.text_scale.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.left.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.top.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.right.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.insets.bottom.to_bits())) * UInt64(0x100000001B3)
        h = (h ^ UInt64(self.locale)) * UInt64(0x100000001B3)
        h = (h ^ UInt64(1 if self.pseudo else 0)) * UInt64(0x100000001B3)
        return h
