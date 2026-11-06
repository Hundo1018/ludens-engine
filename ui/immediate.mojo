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

comptime KEY_NONE = 0
comptime KEY_ENTER = 1
comptime KEY_SPACE = 2
comptime KEY_LEFT = 3
comptime KEY_RIGHT = 4
comptime KEY_UP = 5
comptime KEY_DOWN = 6


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

    def begin_frame(mut self, mx: Float32, my: Float32, down: Bool, key: Int):
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

    def label(mut self, rect: Rect, text: String):
        self.counter += 1
        self.list.text(rect, text, self.theme.text, self.theme.font_size)
