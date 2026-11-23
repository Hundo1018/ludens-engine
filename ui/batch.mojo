"""From draw list to GPU-ready batches (ludens-engine #17): the part of the wgpu draw path that needs no device.

`build_batch` turns a `DrawList` into one vertex array of coloured triangles (6 vertices per rectangle, each
`x y r g b a`), cut into segments wherever the clip rectangle changes (each segment is one scissored draw call), and
a list of text runs with the segment they belong to. Strokes become four rectangles inside the stroked one. Nested
clips are intersected, so a segment's scissor is always the visible area. Text is not turned into glyph quads here: that
needs a font atlas, which belongs to the renderer; the run carries the string, colour, size and rectangle.
`build_batch_font` also turns every text run into glyph quads with an `SdfFont` (`Batch.glyph_verts`, 8 floats per vertex,
see ui/sdf_font.mojo), cut to the scissor of the segment the run belongs to.

Standard library only, so a renderer other than wgpu (or a test) can use the same batches."""
from ui.draw import CMD_CLIP_POP, CMD_CLIP_PUSH, CMD_FILL, CMD_STROKE, CMD_TEXT, Color, DrawList
from ui.geom import Rect
from ui.sdf_font import SdfFont, append_text

comptime FLOATS_PER_VERTEX = 6
comptime VERTS_PER_QUAD = 6


@fieldwise_init
struct Segment(Copyable, Movable):
    var first_vertex: Int
    var vertex_count: Int
    var scissor: Rect
    var clipped: Bool  # False = the whole target


@fieldwise_init
struct TextRun(Copyable, Movable):
    var rect: Rect
    var text: String
    var color: Color
    var size: Float32
    var segment: Int  # index into Batch.segments, for the scissor


struct Batch(Movable):
    var verts: List[Float32]
    var segments: List[Segment]
    var texts: List[TextRun]
    var glyph_verts: List[Float32]  # `build_batch_font` only

    def __init__(out self):
        self.verts = List[Float32]()
        self.segments = List[Segment]()
        self.texts = List[TextRun]()
        self.glyph_verts = List[Float32]()

    def vertex_count(self) -> Int:
        return len(self.verts) // FLOATS_PER_VERTEX


def _intersect(a: Rect, b: Rect) -> Rect:
    var x0 = a.x if a.x > b.x else b.x
    var y0 = a.y if a.y > b.y else b.y
    var x1 = a.x + a.w if a.x + a.w < b.x + b.w else b.x + b.w
    var y1 = a.y + a.h if a.y + a.h < b.y + b.h else b.y + b.h
    return Rect(x0, y0, x1 - x0 if x1 > x0 else Float32(0), y1 - y0 if y1 > y0 else Float32(0))


def _vertex(mut out: List[Float32], x: Float32, y: Float32, c: Color):
    out.append(x)
    out.append(y)
    out.append(c.r)
    out.append(c.g)
    out.append(c.b)
    out.append(c.a)


def _quad(mut out: List[Float32], r: Rect, c: Color) -> Bool:
    if not (r.w > 0 and r.h > 0):
        return False
    var x1 = r.x + r.w
    var y1 = r.y + r.h
    _vertex(out, r.x, r.y, c)
    _vertex(out, x1, r.y, c)
    _vertex(out, r.x, y1, c)
    _vertex(out, x1, r.y, c)
    _vertex(out, x1, y1, c)
    _vertex(out, r.x, y1, c)
    return True


def _segment(mut b: Batch, clips: List[Rect], mut seg_open: Bool):
    """Open the segment draws go into, on first use after a clip change."""
    if not seg_open:
        var clipped = len(clips) > 0
        b.segments.append(Segment(b.vertex_count(), 0, clips[len(clips) - 1] if clipped else Rect(0, 0, 0, 0), clipped))
        seg_open = True


def _add_quad(mut b: Batch, clips: List[Rect], mut seg_open: Bool, r: Rect, c: Color):
    _segment(b, clips, seg_open)
    if _quad(b.verts, r, c):
        b.segments[len(b.segments) - 1].vertex_count += VERTS_PER_QUAD


def build_batch(list: DrawList) -> Batch:
    var b = Batch()
    var clips = List[Rect]()
    var seg_open = False
    for i in range(len(list.cmds)):
        ref c = list.cmds[i]
        if c.kind == CMD_FILL:
            _add_quad(b, clips, seg_open, c.rect, c.color)
        elif c.kind == CMD_STROKE:
            var w = c.value
            var r = c.rect
            if w > 0 and r.w > 0 and r.h > 0:
                if w * 2 >= r.w or w * 2 >= r.h:
                    _add_quad(b, clips, seg_open, r, c.color)  # thicker than half the rectangle: it is solid
                else:
                    _add_quad(b, clips, seg_open, Rect(r.x, r.y, r.w, w), c.color)
                    _add_quad(b, clips, seg_open, Rect(r.x, r.y + r.h - w, r.w, w), c.color)
                    _add_quad(b, clips, seg_open, Rect(r.x, r.y + w, w, r.h - 2 * w), c.color)
                    _add_quad(b, clips, seg_open, Rect(r.x + r.w - w, r.y + w, w, r.h - 2 * w), c.color)
        elif c.kind == CMD_TEXT:
            _segment(b, clips, seg_open)
            b.texts.append(TextRun(c.rect, c.text, c.color, c.value, len(b.segments) - 1))
        elif c.kind == CMD_CLIP_PUSH:
            var r = c.rect
            if len(clips) > 0:
                r = _intersect(r, clips[len(clips) - 1])
            clips.append(r)
            seg_open = False
        elif c.kind == CMD_CLIP_POP:
            if len(clips) > 0:
                _ = clips.pop()
                seg_open = False
    return b^


def build_batch_font(list: DrawList, mut font: SdfFont) -> Batch:
    """`build_batch` plus the glyph quads of every text run, drawn from `font`. Code points the font lacks are counted in `font.missing`."""
    var b = build_batch(list)
    for i in range(len(b.texts)):
        ref t = b.texts[i]
        ref seg = b.segments[t.segment]
        append_text(b.glyph_verts, font, t.rect, t.text, t.color, t.size, seg.scissor, seg.clipped)
    return b^
