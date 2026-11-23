"""The live tuning panel (ludens-engine #119): a `ui/` immediate-mode panel built from a table's schema.

One block per entry, one control per field: a slider for an integer or real with both `min` and `max`, a checkbox for a
boolean, one button per word for an enumeration, a slider per component for a vector. A field the panel cannot edit
(a list, a string, a reference, a number without bounds) is shown as text. Moving a control queues an edit with
`Tuner.set`, which applies at the next tick boundary; the Export button makes `frame` return True, and the caller writes
`Tuner.export_text()` to the table file.

`frame` takes the pointer and the key as plain values, so the panel is the same under the web shell, a native window
and a test that scripts the pointer."""
from game.table import K_BOOL, K_ENUM, K_INT, K_LIST, K_REAL, K_VEC, Field, Value, real_text, value_text
from game.tuning import Tuner
from ui.draw import CMD_TEXT, Color, DrawList
from ui.font import draw_text
from ui.geom import Rect
from ui.immediate import KEY_NONE, Theme, Ui

comptime ROW_H: Float32 = 22.0
comptime PAD: Float32 = 6.0
comptime LABEL_FRAC: Float32 = 0.6  # the left part of a row is its name and value, the rest is the control
comptime TEXT_SCALE: Float32 = 1.5  # `ui.font` dots per font dot: 9 x 10.5 px per character


struct TuningPanel(Movable):
    var ui: Ui
    var open: Bool
    var rows: Int  # controls drawn in the last frame (for tests and layout)

    def __init__(out self):
        self.ui = Ui(Theme.dark())
        self.open = False
        self.rows = 0

    def frame(mut self, mut tuner: Tuner, x: Float32, y: Float32, w: Float32, mx: Float32, my: Float32, down: Bool, key: Int = KEY_NONE) raises -> Bool:
        """Draw the panel with its top-left corner at (x, y), `w` wide, and queue the edits the pointer made. Returns True
        in the frame the Export button was clicked. The draw list of the frame is `self.ui.list`."""
        self.ui.begin_frame(mx, my, down, key)
        self.rows = 0
        var cx = x + PAD
        var cw = w - 2 * PAD
        var lw = cw * LABEL_FRAC
        var cy = y + PAD
        self.ui.label(Rect(cx, cy, cw * 0.6, ROW_H), "TUNING " + tuner.table.schema.table.upper())
        var export = self.ui.button(Rect(x + w - PAD - cw * 0.3, cy, cw * 0.3, ROW_H), "EXPORT")
        cy += ROW_H + PAD
        var sch = tuner.table.schema.copy()
        for e in range(len(tuner.table.entries)):
            var id = tuner.table.entries[e].id
            self.ui.label(Rect(cx, cy, cw, ROW_H), id.upper())
            cy += ROW_H
            for fi in range(len(sch.fields)):
                ref f = sch.fields[fi]
                var cur = tuner.current(e, fi)
                var shown = String("none") if cur.is_none else value_text(f, cur)
                if f.kind == K_LIST:
                    self.ui.label(Rect(cx, cy, cw, ROW_H), f.name + ": " + String(len(cur.nums) + len(cur.strs)) + " elements (edit the file)")
                    cy += ROW_H
                elif cur.is_none:
                    self.ui.label(Rect(cx, cy, cw, ROW_H), f.name + ": none")
                    cy += ROW_H
                elif f.kind == K_BOOL:
                    var next = self.ui.checkbox(Rect(cx, cy, cw, ROW_H), f.name, cur.nums[0] != 0.0)
                    if next != (cur.nums[0] != 0.0):
                        tuner.set(id, f.name, "true" if next else "false")
                    self.rows += 1
                    cy += ROW_H
                elif f.kind == K_ENUM:
                    self.ui.label(Rect(cx, cy, lw, ROW_H), f.name)
                    var n = len(f.values)
                    var bw = (cw - lw) / Float32(n)
                    for k in range(n):
                        var label = f.values[k].upper() if f.values[k] == cur.strs[0] else f.values[k]
                        if self.ui.button(Rect(cx + lw + bw * Float32(k), cy, bw, ROW_H), label):
                            tuner.set(id, f.name, f.values[k])
                    self.rows += 1
                    cy += ROW_H
                elif (f.kind == K_INT or f.kind == K_REAL or f.kind == K_VEC) and f.has_min and f.has_max:
                    var comps = f.size if f.kind == K_VEC else 1
                    var changed = False
                    var out = String()
                    for c in range(comps):
                        var old = Float32(cur.nums[c])
                        var r = Rect(cx + lw, cy, cw - lw, ROW_H)
                        if c == 0:
                            self.ui.label(Rect(cx, cy, lw, ROW_H), f.name + " " + (String(Int(cur.nums[0])) if f.kind == K_INT else real_text(cur.nums[0])))
                        var v = self.ui.slider(r, old, Float32(f.lo), Float32(f.hi))
                        if f.kind == K_INT:
                            v = Float32(Int(v + 0.5)) if v >= 0 else Float32(-Int(-v + 0.5))
                        if v != old:
                            changed = True
                        out += (" " if c > 0 else "") + (String(Int(v)) if f.kind == K_INT else real_text(Float64(v)))
                        self.rows += 1
                        cy += ROW_H
                    if changed:
                        tuner.set(id, f.name, out)
                else:
                    self.ui.label(Rect(cx, cy, cw, ROW_H), f.name + ": " + shown)
                    cy += ROW_H
            cy += PAD
        return export

    def take_list(mut self) -> DrawList:
        """The draw list of the last frame for a renderer that draws fills and strokes only (the HUD pipeline,
        `app/hud.mojo`): every text command becomes dots of the 5 x 7 font (`ui/font.mojo`), centred in its rectangle.
        The panel's own list is left empty; the next `frame` starts a new one."""
        var src = self.ui.list^
        self.ui.list = DrawList()
        var out = DrawList()
        for i in range(src.count()):
            ref c = src.cmds[i]
            if c.kind == CMD_TEXT:
                draw_text(out, c.rect.x + 4, c.rect.y + (c.rect.h - 7 * TEXT_SCALE) * 0.5, c.text, TEXT_SCALE, c.color)
            else:
                out.cmds.append(c.copy())
        return out^
