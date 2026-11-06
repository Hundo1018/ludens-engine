"""Immediate-mode widgets (ludens-shell #17): the caller describes the UI again every frame.

    ui.begin_frame(pointer_x, pointer_y, pointer_down, key)
    if ui.button(Rect(10, 10, 120, 32), "Play"):
        start_game()
    music = ui.checkbox(Rect(10, 52, 160, 24), "Music", music)
    volume = ui.slider(Rect(10, 84, 200, 20), volume, 0, 1)
    draw(ui.list)                       # the DrawList of this frame

Widgets are identified by the order they are called in, which is stable from frame to frame. That needs no widget
objects, no stored callbacks and no tree: a good fit for Mojo, which cannot keep functions in structs.

Pointer: a click is a press and a release both on the same widget; pressing elsewhere and dragging onto a widget is
not a click. Keyboard: Enter and Space activate the focused widget, the arrow keys move focus to the nearest widget in
that direction (`ui.focus`, one frame behind: the rectangles come from the previous frame, as in any immediate-mode
toolkit), and a slider takes Left / Right as steps. A disabled widget draws dimmed, takes no pointer or key input and
is skipped by focus movement."""
from ui.draw import Color, DrawList
from ui.focus import DIR_DOWN, DIR_LEFT, DIR_RIGHT, DIR_UP, focus_next
from ui.geom import Rect
from ui.text import decode_utf8

comptime KEY_NONE = 0
comptime KEY_ENTER = 1
comptime KEY_SPACE = 2
comptime KEY_LEFT = 3
comptime KEY_RIGHT = 4
comptime KEY_UP = 5
comptime KEY_DOWN = 6
comptime KEY_BACKSPACE = 7
comptime KEY_DELETE = 8
comptime KEY_HOME = 9
comptime KEY_END = 10


@fieldwise_init
struct Theme(Copyable, Movable):
    var fill: Color
    var fill_hot: Color
    var fill_active: Color
    var fill_disabled: Color
    var text: Color
    var text_disabled: Color
    var border: Color
    var focus_ring: Color
    var accent: Color
    var font_size: Float32

    @staticmethod
    def dark() -> Self:
        return Self(
            Color.rgb(0.20, 0.22, 0.26), Color.rgb(0.27, 0.30, 0.36), Color.rgb(0.14, 0.45, 0.80), Color.rgb(0.16, 0.17, 0.19),
            Color.rgb(0.92, 0.93, 0.95), Color.rgb(0.50, 0.52, 0.55), Color.rgb(0.35, 0.38, 0.44), Color.rgb(1.00, 0.80, 0.20),
            Color.rgb(0.25, 0.60, 0.95), 14,
        )


struct Ui(Movable):
    var list: DrawList
    var theme: Theme
    var wrap: Bool
    var mx: Float32
    var my: Float32
    var down: Bool
    var was_down: Bool
    var key: Int
    var hot: Int
    var active: Int
    var focus: Int
    var counter: Int
    var rects: List[Rect]  # focusable widgets of this frame
    var ids: List[Int]
    var prev_rects: List[Rect]
    var prev_ids: List[Int]
    var sliders: List[Int]  # ids of this frame's sliders: they keep Left / Right for themselves
    var prev_sliders: List[Int]
    var vlists: List[Int]  # ids of this frame's list boxes: they keep Up / Down for themselves
    var prev_vlists: List[Int]
    var wheel: Float32  # scroll wheel notches this frame, > 0 = down (`begin_frame_input`)
    var typed: List[Int]  # code points typed this frame (`begin_frame_typed`)
    var caret: Int  # in code points, for the focused text field

    def __init__(out self, var theme: Theme):
        self.list = DrawList()
        self.theme = theme^
        self.wrap = False
        self.mx = 0
        self.my = 0
        self.down = False
        self.was_down = False
        self.key = KEY_NONE
        self.hot = -1
        self.active = -1
        self.focus = -1
        self.counter = 0
        self.rects = List[Rect]()
        self.ids = List[Int]()
        self.prev_rects = List[Rect]()
        self.prev_ids = List[Int]()
        self.sliders = List[Int]()
        self.prev_sliders = List[Int]()
        self.vlists = List[Int]()
        self.prev_vlists = List[Int]()
        self.wheel = 0
        self.typed = List[Int]()
        self.caret = 0

    def begin_frame_input(mut self, mx: Float32, my: Float32, down: Bool, key: Int, typed: List[Int], wheel: Float32):
        """`begin_frame_typed` plus the scroll wheel: notches since the last frame, positive = scroll down."""
        self.begin_frame_typed(mx, my, down, key, typed)
        self.wheel = wheel

    def begin_frame_typed(mut self, mx: Float32, my: Float32, down: Bool, key: Int, typed: List[Int]):
        """`begin_frame` plus the code points the user typed since the last frame (what a text field inserts)."""
        self.begin_frame(mx, my, down, key)
        self.typed = typed.copy()
        self.wheel = 0

    def begin_frame(mut self, mx: Float32, my: Float32, down: Bool, key: Int):
        self.typed = List[Int]()
        self.was_down = self.down
        self.mx = mx
        self.my = my
        self.down = down
        self.key = key
        self.hot = -1
        self.counter = 0
        self.list = DrawList()
        self.prev_rects = self.rects^
        self.prev_ids = self.ids^
        self.prev_sliders = self.sliders^
        self.prev_vlists = self.vlists^
        self.vlists = List[Int]()
        self.rects = List[Rect]()
        self.ids = List[Int]()
        self.sliders = List[Int]()
        var dir = -1
        if key == KEY_LEFT:
            dir = DIR_LEFT
        elif key == KEY_RIGHT:
            dir = DIR_RIGHT
        elif key == KEY_UP:
            dir = DIR_UP
        elif key == KEY_DOWN:
            dir = DIR_DOWN
        var on_slider = False
        for i in range(len(self.prev_sliders)):
            if self.prev_sliders[i] == self.focus:
                on_slider = True
        if on_slider and (dir == DIR_LEFT or dir == DIR_RIGHT):
            dir = -1  # a focused slider takes Left / Right as steps
        for i in range(len(self.prev_vlists)):
            if self.prev_vlists[i] == self.focus and (dir == DIR_UP or dir == DIR_DOWN):
                dir = -1  # a focused list box takes Up / Down to move its selection
        if dir >= 0 and len(self.prev_rects) > 0:
            var at = -1
            for i in range(len(self.prev_ids)):
                if self.prev_ids[i] == self.focus:
                    at = i
            var to = focus_next(self.prev_rects, at, dir, self.wrap)
            if to >= 0:
                self.focus = self.prev_ids[to]

    def pressed(self) -> Bool:
        return self.down and not self.was_down

    def released(self) -> Bool:
        return self.was_down and not self.down

    def _begin_widget(mut self, rect: Rect, enabled: Bool) -> Int:
        var id = self.counter
        self.counter += 1
        if enabled:
            self.rects.append(rect)
            self.ids.append(id)
            if rect.contains(self.mx, self.my):
                self.hot = id
        return id

    def _clicked(mut self, id: Int, rect: Rect, enabled: Bool) -> Bool:
        """Pointer and keyboard interaction of widget `id`: True on the frame it is activated."""
        if not enabled:
            if self.active == id:
                self.active = -1
            return False
        var clicked = False
        if self.pressed() and self.hot == id:
            self.active = id
            self.focus = id
        if self.released() and self.active == id:
            clicked = self.hot == id
            self.active = -1
        if self.focus == id and (self.key == KEY_ENTER or self.key == KEY_SPACE):
            clicked = True
        return clicked

    def _chrome(mut self, id: Int, rect: Rect, enabled: Bool):
        """The background and the focus ring shared by buttons and boxes."""
        var c = self.theme.fill
        if not enabled:
            c = self.theme.fill_disabled
        elif self.active == id and self.down:
            c = self.theme.fill_active
        elif self.hot == id:
            c = self.theme.fill_hot
        self.list.fill(rect, c)
        self.list.stroke(rect, self.theme.border, 1)
        if enabled and self.focus == id:
            self.list.stroke(rect, self.theme.focus_ring, 2)

    def button(mut self, rect: Rect, label: String, enabled: Bool = True) -> Bool:
        var id = self._begin_widget(rect, enabled)
        var clicked = self._clicked(id, rect, enabled)
        self._chrome(id, rect, enabled)
        self.list.text(rect, label, self.theme.text if enabled else self.theme.text_disabled, self.theme.font_size)
        return clicked

    def checkbox(mut self, rect: Rect, label: String, value: Bool, enabled: Bool = True) -> Bool:
        """Returns the new value: `music = ui.checkbox(r, "Music", music)`."""
        var id = self._begin_widget(rect, enabled)
        var clicked = self._clicked(id, rect, enabled)
        var next = (not value) if clicked else value
        self._chrome(id, rect, enabled)
        var box = Rect(rect.x + 4, rect.y + (rect.h - 14) * 0.5, 14, 14)
        self.list.stroke(box, self.theme.border, 1)
        if next:
            self.list.fill(Rect(box.x + 3, box.y + 3, 8, 8), self.theme.accent)
        self.list.text(Rect(rect.x + 24, rect.y, rect.w - 24, rect.h), label, self.theme.text if enabled else self.theme.text_disabled, self.theme.font_size)
        return next

    def slider(mut self, rect: Rect, value: Float32, lo: Float32, hi: Float32, enabled: Bool = True) -> Float32:
        """Returns the new value. Drag with the pointer, or Left / Right when focused (a twentieth of the range)."""
        var id = self._begin_widget(rect, enabled)
        if enabled:
            self.sliders.append(id)
        _ = self._clicked(id, rect, enabled)
        var next = value
        if enabled:
            if self.active == id and self.down and rect.w > 0:
                var t = (self.mx - rect.x) / rect.w
                t = Float32(0) if t < 0 else (Float32(1) if t > 1 else t)
                next = lo + t * (hi - lo)
            elif self.focus == id and self.key == KEY_RIGHT:
                next = value + (hi - lo) / 20
            elif self.focus == id and self.key == KEY_LEFT:
                next = value - (hi - lo) / 20
            next = lo if next < lo else (hi if next > hi else next)
        self._chrome(id, rect, enabled)
        var t = (next - lo) / (hi - lo) if hi > lo else Float32(0)
        self.list.fill(Rect(rect.x, rect.y, rect.w * t, rect.h), self.theme.accent)
        return next

    def text_field(mut self, rect: Rect, value: String, enabled: Bool = True) -> String:
        """Returns the new text: `name = ui.text_field(r, name)`. A click focuses it and puts the caret at the end;
        typed code points insert at the caret; Backspace / Delete remove; Left / Right / Home / End move the caret
        (the field keeps Left / Right for itself, like a slider). Enter and Space are not inserted: Space arrives as
        a typed code point, Enter is for the caller."""
        var id = self._begin_widget(rect, enabled)
        if enabled:
            self.sliders.append(id)
        var was_focus = self.focus == id
        _ = self._clicked(id, rect, enabled)
        var cps = decode_utf8(value)
        if enabled and self.focus == id and not was_focus:
            self.caret = len(cps)
        var next = value
        if enabled and self.focus == id:
            if self.caret > len(cps):
                self.caret = len(cps)
            var bytes = List[UInt8]()
            for b in value.as_bytes():
                bytes.append(b)
            var at = cps[self.caret].start if self.caret < len(cps) else len(bytes)
            if self.key == KEY_BACKSPACE and self.caret > 0:
                var from_b = cps[self.caret - 1].start
                var out = List[UInt8]()
                for i in range(len(bytes)):
                    if i < from_b or i >= at:
                        out.append(bytes[i])
                bytes = out^
                self.caret -= 1
            elif self.key == KEY_DELETE and self.caret < len(cps):
                var to_b = cps[self.caret].end
                var out = List[UInt8]()
                for i in range(len(bytes)):
                    if i < at or i >= to_b:
                        out.append(bytes[i])
                bytes = out^
            elif self.key == KEY_LEFT and self.caret > 0:
                self.caret -= 1
            elif self.key == KEY_RIGHT and self.caret < len(cps):
                self.caret += 1
            elif self.key == KEY_HOME:
                self.caret = 0
            elif self.key == KEY_END:
                self.caret = len(cps)
            if len(self.typed) > 0:
                var ins = List[UInt8]()
                var added = 0
                for cp in self.typed:
                    if cp >= 0x20 and cp != 0x7F:
                        for b in String(chr(cp)).as_bytes():
                            ins.append(b)
                        added += 1
                var out = List[UInt8]()
                for i in range(at):
                    out.append(bytes[i])
                for b in ins:
                    out.append(b)
                for i in range(at, len(bytes)):
                    out.append(bytes[i])
                if self.key == KEY_BACKSPACE or self.key == KEY_DELETE:
                    pass  # an edit key and typed text in one frame: keep the edit, ignore the text
                else:
                    bytes = out^
                    self.caret += added
            next = String(unsafe_from_utf8=bytes)
        self._chrome(id, rect, enabled)
        self.list.text(Rect(rect.x + 4, rect.y, rect.w - 8, rect.h), next, self.theme.text if enabled else self.theme.text_disabled, self.theme.font_size)
        if enabled and self.focus == id:
            # caret: a thin bar after `caret` characters, 0.6 em per character (the real advance is the renderer's job)
            var cx = rect.x + 4 + Float32(self.caret) * self.theme.font_size * 0.6
            self.list.fill(Rect(cx, rect.y + 3, 1, rect.h - 6), self.theme.accent)
        return next

    def list_box(mut self, rect: Rect, items: List[String], selected: Int, mut top: Int, row_h: Float32 = 24, enabled: Bool = True) -> Int:
        """Returns the selected row (-1 = none). `top` is the first visible row, kept by the caller; it follows the
        selection so the selected row stays visible. A click on a row selects it; Up / Down move the selection when
        the list has focus. Rows that do not fit are clipped, not drawn."""
        var id = self._begin_widget(rect, enabled)
        if enabled:
            self.vlists.append(id)
        _ = self._clicked(id, rect, enabled)
        var visible = Int(rect.h / row_h)
        if visible < 1:
            visible = 1
        var next = selected
        if enabled:
            if self.pressed() and self.hot == id:
                var row = top + Int((self.my - rect.y) / row_h)
                if row >= 0 and row < len(items):
                    next = row
            elif self.focus == id and self.key == KEY_DOWN and next < len(items) - 1:
                next += 1
            elif self.focus == id and self.key == KEY_UP and next > 0:
                next -= 1
            elif self.focus == id and self.key == KEY_HOME and len(items) > 0:
                next = 0
            elif self.focus == id and self.key == KEY_END and len(items) > 0:
                next = len(items) - 1
        if next >= len(items):
            next = len(items) - 1
        if enabled and self.hot == id and self.wheel != 0:
            top += Int(self.wheel)  # the wheel moves the view without changing the selection
        elif next >= 0 and next != selected:
            if next < top:
                top = next
            elif next >= top + visible:
                top = next - visible + 1
        elif next >= 0 and (next < top or next >= top + visible) and self.wheel == 0 and self.focus == id:
            top = next if next < top else next - visible + 1
        if top > len(items) - visible:
            top = len(items) - visible
        if top < 0:
            top = 0
        self._chrome(id, rect, enabled)
        self.list.push_clip(rect)
        for k in range(visible):
            var i = top + k
            if i >= len(items):
                break
            var r = Rect(rect.x, rect.y + Float32(k) * row_h, rect.w, row_h)
            if i == next:
                self.list.fill(r, self.theme.accent)
            self.list.text(Rect(r.x + 4, r.y, r.w - 8, r.h), items[i], self.theme.text if enabled else self.theme.text_disabled, self.theme.font_size)
        self.list.pop_clip()
        return next

    def label(mut self, rect: Rect, text: String):
        self.counter += 1
        self.list.text(rect, text, self.theme.text, self.theme.font_size)
