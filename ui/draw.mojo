"""The draw list: what the widgets produce and a renderer consumes (ludens-engine #17).

A flat list of commands (fill a rectangle, stroke one, draw a text run, push / pop a clip). It holds no GPU object
and no font, so the widgets can be tested without a device and the same list can be drawn by wgpu, by a software
rasterizer or compared as a hash. `DrawList.hash()` is over every field of every command in order: two frames that
draw the same thing hash the same, and any change (a colour, a position, a character) changes it."""
from ui.geom import Rect

comptime CMD_FILL = 0
comptime CMD_STROKE = 1
comptime CMD_TEXT = 2
comptime CMD_CLIP_PUSH = 3
comptime CMD_CLIP_POP = 4


@fieldwise_init
struct Color(Copyable, ImplicitlyCopyable, Movable):
    var r: Float32
    var g: Float32
    var b: Float32
    var a: Float32

    @staticmethod
    def rgb(r: Float32, g: Float32, b: Float32) -> Self:
        return Self(r, g, b, 1)


@fieldwise_init
struct DrawCmd(Copyable, Movable):
    var kind: Int
    var rect: Rect
    var color: Color
    var value: Float32  # stroke width, or font size for text
    var text: String


def _mix(h: UInt64, v: UInt64) -> UInt64:
    return (h ^ v) * UInt64(0x100000001B3)


struct DrawList(Movable):
    var cmds: List[DrawCmd]

    def __init__(out self):
        self.cmds = List[DrawCmd]()

    def fill(mut self, r: Rect, c: Color):
        self.cmds.append(DrawCmd(CMD_FILL, r, c, 0, String()))

    def stroke(mut self, r: Rect, c: Color, width: Float32):
        self.cmds.append(DrawCmd(CMD_STROKE, r, c, width, String()))

    def text(mut self, r: Rect, s: String, c: Color, size: Float32):
        self.cmds.append(DrawCmd(CMD_TEXT, r, c, size, s))

    def push_clip(mut self, r: Rect):
        self.cmds.append(DrawCmd(CMD_CLIP_PUSH, r, Color(0, 0, 0, 0), 0, String()))

    def pop_clip(mut self):
        self.cmds.append(DrawCmd(CMD_CLIP_POP, Rect(0, 0, 0, 0), Color(0, 0, 0, 0), 0, String()))

    def count(self) -> Int:
        return len(self.cmds)

    def hash(self) -> UInt64:
        var h = UInt64(0xCBF29CE484222325)
        for i in range(len(self.cmds)):
            ref c = self.cmds[i]
            h = _mix(h, UInt64(c.kind))
            h = _mix(h, UInt64(c.rect.x.to_bits()))
            h = _mix(h, UInt64(c.rect.y.to_bits()))
            h = _mix(h, UInt64(c.rect.w.to_bits()))
            h = _mix(h, UInt64(c.rect.h.to_bits()))
            h = _mix(h, UInt64(c.color.r.to_bits()))
            h = _mix(h, UInt64(c.color.g.to_bits()))
            h = _mix(h, UInt64(c.color.b.to_bits()))
            h = _mix(h, UInt64(c.color.a.to_bits()))
            h = _mix(h, UInt64(c.value.to_bits()))
            var bytes = c.text.as_bytes()
            for k in range(len(bytes)):
                h = _mix(h, UInt64(bytes[k]))
            h = _mix(h, UInt64(len(bytes)))
        return h
