"""A small flex-style layout: rows and columns of boxes (ludens-shell #17).

One pass to measure, one to arrange, both plain `Float32` arithmetic in a fixed order: laying the same tree out
twice gives identical bits (tested). Agreement between native x86-64 and wasm64 follows from both being built
without FMA contraction but has not been measured yet (ludens-shell #17); a target that contracts to FMA (aarch64)
may differ in the last bit.

A node is a box with a direction (`ROW` or `COLUMN`), an optional fixed `width` / `height` (< 0 = size to content),
`grow` (its share of the space left on the main axis), `padding`, a `gap` between children, and how children sit on
the cross axis (`align`) and the main axis (`justify`). A leaf gets its content size from the caller
(`content_w` / `content_h`: a measured text run, an image). Children that do not fit shrink in proportion to their
size.
"""
from std.math import isfinite
from ui.geom import Insets, Rect

comptime ROW = 0
comptime COLUMN = 1

comptime ALIGN_START = 0
comptime ALIGN_CENTER = 1
comptime ALIGN_END = 2
comptime ALIGN_STRETCH = 3

comptime JUSTIFY_START = 0
comptime JUSTIFY_CENTER = 1
comptime JUSTIFY_END = 2
comptime JUSTIFY_SPACE_BETWEEN = 3


struct Node(Copyable, Movable):
    var direction: Int
    var width: Float32
    var height: Float32
    var grow: Float32
    var padding: Insets
    var gap: Float32
    var align: Int
    var justify: Int
    var content_w: Float32
    var content_h: Float32
    var children: List[Int]
    var rect: Rect

    def __init__(out self):
        self.direction = ROW
        self.width = -1
        self.height = -1
        self.grow = 0
        self.padding = Insets.none()
        self.gap = 0
        self.align = ALIGN_STRETCH
        self.justify = JUSTIFY_START
        self.content_w = 0
        self.content_h = 0
        self.children = List[Int]()
        self.rect = Rect(0, 0, 0, 0)


struct Tree(Movable):
    var nodes: List[Node]

    def __init__(out self):
        self.nodes = List[Node]()

    def add(mut self, var node: Node, parent: Int = -1) raises -> Int:
        """Append `node` (as the last child of `parent`, or as a root when `parent` < 0). Returns its id."""
        if not (isfinite(node.width) and isfinite(node.height) and isfinite(node.grow) and isfinite(node.gap)):
            raise Error("layout: sizes, grow and gap must be finite")
        if node.grow < 0 or node.gap < 0:
            raise Error("layout: grow and gap must be >= 0")
        if node.direction != ROW and node.direction != COLUMN:
            raise Error("layout: unknown direction " + String(node.direction))
        if parent >= len(self.nodes):
            raise Error("layout: parent " + String(parent) + " does not exist")
        var id = len(self.nodes)
        self.nodes.append(node^)
        if parent >= 0:
            self.nodes[parent].children.append(id)
        return id

    def rect(self, id: Int) -> Rect:
        return self.nodes[id].rect

    # ------------------------------------------------------------ measure

    def measure(self, id: Int) -> Tuple[Float32, Float32]:
        """The size node `id` wants: its fixed size where set, else what its content / children need."""
        ref n = self.nodes[id]
        var w = n.content_w + n.padding.horizontal()
        var h = n.content_h + n.padding.vertical()
        if len(n.children) > 0:
            var main = Float32(0)
            var cross = Float32(0)
            for k in range(len(n.children)):
                var m = self.measure(n.children[k])
                var cm = m[0] if n.direction == ROW else m[1]
                var cc = m[1] if n.direction == ROW else m[0]
                main += cm
                if cc > cross:
                    cross = cc
            main += n.gap * Float32(len(n.children) - 1)
            if n.direction == ROW:
                w = main + n.padding.horizontal()
                h = cross + n.padding.vertical()
            else:
                w = cross + n.padding.horizontal()
                h = main + n.padding.vertical()
        if n.width >= 0:
            w = n.width
        if n.height >= 0:
            h = n.height
        return (w, h)

    # ------------------------------------------------------------ arrange

    def layout(mut self, root: Int, available: Rect):
        """Place `root` in `available` (its own fixed size wins) and everything below it."""
        var w = self.nodes[root].width if self.nodes[root].width >= 0 else available.w
        var h = self.nodes[root].height if self.nodes[root].height >= 0 else available.h
        self._arrange(root, Rect(available.x, available.y, w, h))

    def _arrange(mut self, id: Int, r: Rect):
        self.nodes[id].rect = r
        var count = len(self.nodes[id].children)
        if count == 0:
            return
        var inner = r.inset(self.nodes[id].padding)
        var row = self.nodes[id].direction == ROW
        var gap = self.nodes[id].gap
        var inner_main = inner.w if row else inner.h
        var inner_cross = inner.h if row else inner.w

        var base = List[Float32]()
        var cross_want = List[Float32]()
        var total = Float32(0)
        var grow_sum = Float32(0)
        for k in range(count):
            var c = self.nodes[id].children[k]
            var m = self.measure(c)
            var b = m[0] if row else m[1]
            base.append(b)
            cross_want.append(m[1] if row else m[0])
            total += b
            grow_sum += self.nodes[c].grow
        total += gap * Float32(count - 1)

        var free = inner_main - total
        var sizes = List[Float32]()
        for k in range(count):
            var c = self.nodes[id].children[k]
            var s = base[k]
            if free > 0 and grow_sum > 0:
                s += free * self.nodes[c].grow / grow_sum
            elif free < 0 and total > 0:
                var content = total - gap * Float32(count - 1)
                if content > 0:
                    s += free * base[k] / content
                if s < 0:
                    s = 0
            sizes.append(s)

        var used = Float32(0)
        for k in range(count):
            used += sizes[k]
        used += gap * Float32(count - 1)
        var left = inner_main - used
        var start = Float32(0)
        var between = gap
        var j = self.nodes[id].justify
        if grow_sum == 0 and left > 0:
            if j == JUSTIFY_CENTER:
                start = left * 0.5
            elif j == JUSTIFY_END:
                start = left
            elif j == JUSTIFY_SPACE_BETWEEN and count > 1:
                between = gap + left / Float32(count - 1)

        var pos = start
        var a = self.nodes[id].align
        for k in range(count):
            var c = self.nodes[id].children[k]
            var cross = cross_want[k]
            var off = Float32(0)
            if a == ALIGN_STRETCH:
                var fixed = self.nodes[c].height >= 0 if row else self.nodes[c].width >= 0
                if not fixed:
                    cross = inner_cross
            elif a == ALIGN_CENTER:
                off = (inner_cross - cross) * 0.5
            elif a == ALIGN_END:
                off = inner_cross - cross
            var cr: Rect
            if row:
                cr = Rect(inner.x + pos, inner.y + off, sizes[k], cross)
            else:
                cr = Rect(inner.x + off, inner.y + pos, cross, sizes[k])
            self._arrange(c, cr)
            pos += sizes[k] + between
