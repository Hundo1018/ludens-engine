"""Deterministic helpers for testing ui/ (ludens-shell #17): a seeded generator, random layout trees and a hash of
the rectangles they lay out to. Standard library only. The unit tests and the native / wasm64 parity program
(`app/ui_parity.mojo`) share them, so both look at the same trees."""
from ui.batch import build_batch
from ui.geom import Insets, Rect
from ui.layout import COLUMN, ROW, Node, Tree


def box(direction: Int = ROW, width: Float32 = -1, height: Float32 = -1, grow: Float32 = 0) -> Node:
    var n = Node()
    n.direction = direction
    n.width = width
    n.height = height
    n.grow = grow
    return n^


def fnv(h: UInt64, v: Float32) -> UInt64:
    return (h ^ UInt64(v.to_bits())) * UInt64(0x100000001B3)


def hash_tree(t: Tree) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(t.nodes)):
        var r = t.nodes[i].rect
        h = fnv(h, r.x)
        h = fnv(h, r.y)
        h = fnv(h, r.w)
        h = fnv(h, r.h)
    return h


struct Lcg:
    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next(mut self) -> UInt64:
        self.s = self.s * 6364136223846793005 + 1442695040888963407
        return self.s >> 33

    def below(mut self, n: Int) -> Int:
        return Int(self.next() % UInt64(n))


def random_tree(mut rng: Lcg, mut t: Tree, parent: Int, depth: Int) raises:
    var count = 1 + rng.below(4)
    for _ in range(count):
        var n = box(ROW if rng.below(2) == 0 else COLUMN)
        if rng.below(3) == 0:
            n.width = Float32(20 + rng.below(80))
        if rng.below(3) == 0:
            n.height = Float32(20 + rng.below(60))
        n.grow = Float32(rng.below(3))
        n.gap = Float32(rng.below(4))
        n.padding = Insets.all(Float32(rng.below(4)))
        n.align = rng.below(4)
        n.justify = rng.below(4)
        n.content_w = Float32(rng.below(40))
        n.content_h = Float32(rng.below(30))
        var id = t.add(n^, parent)
        if depth > 0 and rng.below(2) == 0:
            random_tree(rng, t, id, depth - 1)


def layout_parity_hash(seed: UInt64, trees: Int) raises -> UInt64:
    """Lay out `trees` generated trees in a 500 x 400 area and fold the hash of every tree's rectangles."""
    var rng = Lcg(seed)
    var all_hash = UInt64(0xCBF29CE484222325)
    for _ in range(trees):
        var t = Tree()
        var rt = t.add(box(ROW, -1, -1))
        random_tree(rng, t, rt, 2)
        t.layout(rt, Rect(0, 0, 500, 400))
        all_hash = (all_hash ^ hash_tree(t)) * UInt64(0x100000001B3)
    return all_hash


def widget_parity_hash() raises -> UInt64:
    """Run a scripted pointer / key sequence through a small screen (buttons, checkbox, slider) and fold the draw
    list's hash of every frame plus the widget values."""
    from ui.immediate import Theme, Ui

    var ui = Ui(Theme.dark())
    var music = False
    var volume = Float32(0.5)
    var acc = UInt64(0xCBF29CE484222325)
    # x, y, pointer down, key (3 = left, 4 = right)
    var pts = [(10, 10, 0, 0), (10, 10, 1, 0), (10, 10, 0, 0), (10, 60, 0, 0), (10, 60, 1, 0), (10, 60, 0, 0),
               (50, 95, 0, 0), (50, 95, 1, 0), (150, 95, 1, 0), (500, 95, 1, 0), (100, 95, 0, 0),
               (600, 600, 0, 3), (600, 600, 0, 4), (600, 600, 0, 3), (130, 10, 0, 0)]
    for k in range(len(pts)):
        var p = pts[k]
        ui.begin_frame(Float32(p[0]), Float32(p[1]), p[2] == 1, p[3])
        var clicked = 0
        if ui.button(Rect(0, 0, 100, 30), "A"):
            clicked |= 1
        if ui.button(Rect(120, 0, 100, 30), "B"):
            clicked |= 2
        if ui.button(Rect(240, 0, 100, 30), "C", False):
            clicked |= 4
        music = ui.checkbox(Rect(0, 50, 160, 24), "Music", music)
        volume = ui.slider(Rect(0, 90, 200, 20), volume, 0, 1)
        acc = (acc ^ ui.list.hash()) * UInt64(0x100000001B3)
        acc = fnv(acc, volume)
        acc = (acc ^ UInt64(clicked) ^ (UInt64(1) if music else UInt64(0))) * UInt64(0x100000001B3)
    # text field and list box: typed text (ASCII and CJK), edit keys, selection and a scrolling view
    var tf = Ui(Theme.dark())
    var text = String("ab")
    var items = List[String]()
    for i in range(8):
        items.append("row " + String(i))
    var sel = -1
    var top = 0
    var steps = [(10, 10, 0, 0, 0), (10, 10, 1, 0, 0), (10, 10, 0, 0, 0), (600, 600, 0, 0, 0x63), (600, 600, 0, 3, 0),
                 (600, 600, 0, 0, 0x4E2D), (600, 600, 0, 7, 0), (600, 600, 0, 8, 0), (10, 60, 0, 0, 0), (10, 60, 1, 0, 0),
                 (600, 600, 0, 6, 0), (600, 600, 0, 6, 0), (600, 600, 0, 6, 0), (600, 600, 0, 10, 0), (600, 600, 0, 9, 0)]
    for k in range(len(steps)):
        var st = steps[k]
        var typed = List[Int]()
        if st[4] != 0:
            typed.append(st[4])
        tf.begin_frame_typed(Float32(st[0]), Float32(st[1]), st[2] == 1, st[3], typed)
        text = tf.text_field(Rect(0, 0, 200, 24), text)
        sel = tf.list_box(Rect(0, 40, 100, 72), items, sel, top)
        acc = (acc ^ tf.list.hash()) * UInt64(0x100000001B3)
        var batch = build_batch(tf.list)
        for v in batch.verts:
            acc = fnv(acc, v)
        acc = fnv(acc, Float32(len(batch.segments)))
        acc = (acc ^ UInt64(sel + 1) ^ UInt64(top << 8) ^ UInt64(text.byte_length() << 16) ^ UInt64(tf.caret << 24)) * UInt64(0x100000001B3)
    # touch gestures: a tap, a drag and a pinch from scripted fingers
    from ui.gesture import GestureRecognizer, Touch
    var gr = GestureRecognizer()
    var t = 0
    var script = [(1, 50, 50, 0, 0), (1, 52, 51, 0, 0), (0, 0, 0, 0, 0), (1, 100, 100, 0, 0), (1, 131, 100, 0, 0),
                  (1, 137, 109, 0, 0), (0, 0, 0, 0, 0), (2, 100, 100, 200, 100), (2, 75, 100, 225, 100), (2, 85, 110, 235, 110),
                  (1, 85, 110, 0, 0), (0, 0, 0, 0, 0), (1, 10, 10, 0, 0)]
    for k in range(len(script)):
        var f = script[k]
        var touches = List[Touch]()
        if f[0] >= 1:
            touches.append(Touch(Float32(f[1]), Float32(f[2])))
        if f[0] == 2:
            touches.append(Touch(Float32(f[3]), Float32(f[4])))
        t += 16 if k < 12 else 700
        for e in gr.feed(touches, t):
            acc = fnv(acc, Float32(e.kind))
            acc = fnv(acc, e.x)
            acc = fnv(acc, e.y)
            acc = fnv(acc, e.dx)
            acc = fnv(acc, e.dy)
            acc = fnv(acc, e.scale)
    return acc
