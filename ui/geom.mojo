"""Rectangles and insets for the shared UI toolkit (ludens-shell #17)."""


@fieldwise_init
struct Insets(Copyable, ImplicitlyCopyable, Movable):
    var left: Float32
    var top: Float32
    var right: Float32
    var bottom: Float32

    @staticmethod
    def all(v: Float32) -> Self:
        return Self(v, v, v, v)

    @staticmethod
    def none() -> Self:
        return Self(0, 0, 0, 0)

    def horizontal(self) -> Float32:
        return self.left + self.right

    def vertical(self) -> Float32:
        return self.top + self.bottom


@fieldwise_init
struct Rect(Copyable, ImplicitlyCopyable, Movable):
    var x: Float32
    var y: Float32
    var w: Float32
    var h: Float32

    def right(self) -> Float32:
        return self.x + self.w

    def bottom(self) -> Float32:
        return self.y + self.h

    def center_x(self) -> Float32:
        return self.x + self.w * 0.5

    def center_y(self) -> Float32:
        return self.y + self.h * 0.5

    def contains(self, px: Float32, py: Float32) -> Bool:
        return px >= self.x and px < self.right() and py >= self.y and py < self.bottom()

    def inset(self, i: Insets) -> Self:
        """The rectangle shrunk by `i`; a side that would go negative collapses to zero size."""
        var w = self.w - i.horizontal()
        var h = self.h - i.vertical()
        return Self(self.x + i.left, self.y + i.top, w if w > 0 else Float32(0), h if h > 0 else Float32(0))
