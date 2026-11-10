"""The ui/ draw list and immediate-mode widgets (ludens-engine #17). Standard library only.

Every case feeds the toolkit a scripted sequence of frames (pointer position, button, key) and checks what it
reports: clicks, values, focus, and the draw list's hash.

Build and run: `pixi run -e wasm test-ui`."""
from ui.draw import CMD_FILL, CMD_STROKE, CMD_TEXT, Color, DrawList
from ui.geom import Rect
from ui.immediate import KEY_BACKSPACE, KEY_DELETE, KEY_END, KEY_HOME, KEY_ENTER, KEY_DOWN, KEY_LEFT, KEY_NONE, KEY_RIGHT, KEY_SPACE, KEY_UP, Theme, Ui


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

    def near(mut self, got: Float32, want: Float32, label: String):
        var d = got - want
        if d < 0:
            d = -d
        self.ok(d <= 1e-5, label + " (got " + String(got) + " want " + String(want) + ")")

    def eq(mut self, got: Int, want: Int, label: String):
        self.ok(got == want, label + " (got " + String(got) + " want " + String(want) + ")")


struct World:
    """What the scene under test keeps between frames."""
    var music: Bool
    var volume: Float32

    def __init__(out self):
        self.music = False
        self.volume = 0.5


def frame(mut ui: Ui, mut w: World, mx: Float32, my: Float32, down: Bool, key: Int = KEY_NONE) -> Int:
    """One frame of a small screen: A and B buttons, a disabled C, a checkbox, a slider. Returns a bit per clicked button."""
    ui.begin_frame(mx, my, down, key)
    var out = 0
    if ui.button(Rect(0, 0, 100, 30), "A"):
        out |= 1
    if ui.button(Rect(120, 0, 100, 30), "B"):
        out |= 2
    if ui.button(Rect(240, 0, 100, 30), "C", False):
        out |= 4
    w.music = ui.checkbox(Rect(0, 50, 160, 24), "Music", w.music)
    w.volume = ui.slider(Rect(0, 90, 200, 20), w.volume, 0, 1)
    return out


def click_at(mut ui: Ui, mut w: World, x: Float32, y: Float32) -> Int:
    """Move there, press, release: the OR of everything clicked."""
    var got = frame(ui, w, x, y, False)
    got |= frame(ui, w, x, y, True)
    got |= frame(ui, w, x, y, False)
    return got


def main() raises:
    var c = Check()

    # 1. Pointer: a click is press and release on the same widget; only the release frame reports it.
    var ui = Ui(Theme.dark())
    var w = World()
    c.eq(frame(ui, w, 10, 10, False), 0, "hover: no click")
    c.eq(ui.hot, 0, "hover: widget 0 is hot")
    c.eq(frame(ui, w, 10, 10, True), 0, "press: not a click yet")
    c.eq(ui.active, 0, "press: widget 0 is active")
    c.eq(frame(ui, w, 10, 10, False), 1, "release on the same widget: clicked")
    c.eq(ui.active, -1, "release: nothing is active")
    c.eq(frame(ui, w, 10, 10, False), 0, "the click is reported once")

    # 2. Pressing inside and releasing outside, or pressing outside and dragging in, is not a click.
    var u2 = Ui(Theme.dark())
    var w2 = World()
    _ = frame(u2, w2, 10, 10, False)
    _ = frame(u2, w2, 10, 10, True)
    c.eq(frame(u2, w2, 500, 500, False), 0, "press inside, release outside: no click")
    c.eq(u2.active, -1, "...and the widget is no longer active")
    var u3 = Ui(Theme.dark())
    var w3 = World()
    _ = frame(u3, w3, 500, 500, False)
    _ = frame(u3, w3, 500, 500, True)
    _ = frame(u3, w3, 10, 10, True)
    c.eq(frame(u3, w3, 10, 10, False), 0, "press outside, drag in, release: no click")

    # 3. A disabled button takes no input and draws dimmed.
    var u4 = Ui(Theme.dark())
    var w4 = World()
    c.eq(click_at(u4, w4, 250, 10), 0, "disabled button: no click")
    c.eq(u4.focus, -1, "...and it does not take focus")
    _ = frame(u4, w4, 600, 600, False)
    var third = u4.list.cmds[6].copy()  # fill of the third button: A, B take three commands each
    c.ok(third.kind == CMD_FILL and third.color.r == u4.theme.fill_disabled.r and third.color.g == u4.theme.fill_disabled.g, "disabled button: filled with the disabled colour")

    # 4. Keyboard: Enter and Space activate the focused widget; arrows move focus; disabled widgets are skipped.
    var u5 = Ui(Theme.dark())
    var w5 = World()
    c.eq(click_at(u5, w5, 10, 10), 1, "click A")
    c.eq(u5.focus, 0, "A has focus")
    _ = frame(u5, w5, 600, 600, False)
    c.eq(frame(u5, w5, 600, 600, False, KEY_ENTER), 1, "Enter activates the focused button")
    c.eq(frame(u5, w5, 600, 600, False, KEY_SPACE), 1, "Space activates it too")
    c.eq(frame(u5, w5, 600, 600, False, KEY_LEFT), 0, "another key does nothing to a button")
    _ = frame(u5, w5, 600, 600, False, KEY_RIGHT)
    c.eq(u5.focus, 1, "Right moves focus from A to B")
    c.eq(frame(u5, w5, 600, 600, False, KEY_ENTER), 2, "Enter now activates B")
    _ = frame(u5, w5, 600, 600, False, KEY_RIGHT)
    c.eq(u5.focus, 1, "Right from B stays on B: C is disabled and nothing else lies to the right")
    _ = frame(u5, w5, 600, 600, False, KEY_DOWN)
    c.eq(u5.focus, 3, "Down from B goes to the checkbox (widget 3)")
    _ = frame(u5, w5, 600, 600, False, KEY_UP)
    c.eq(u5.focus, 0, "Up from the checkbox goes back to A (the nearest above it)")
    u5.wrap = True
    _ = frame(u5, w5, 600, 600, False, KEY_RIGHT)
    _ = frame(u5, w5, 600, 600, False, KEY_RIGHT)
    c.eq(u5.focus, 0, "with wrap, Right from B continues from the left end of the row")

    # 5. Checkbox and slider.
    var u6 = Ui(Theme.dark())
    var w6 = World()
    c.ok(not w6.music, "music starts off")
    _ = click_at(u6, w6, 10, 60)
    c.ok(w6.music, "a click turns the checkbox on")
    _ = click_at(u6, w6, 10, 60)
    c.ok(not w6.music, "...and off again")

    var u7 = Ui(Theme.dark())
    var w7 = World()
    _ = frame(u7, w7, 50, 95, False)
    _ = frame(u7, w7, 50, 95, True)
    c.near(w7.volume, 0.25, "press at a quarter of the slider sets 0.25")
    _ = frame(u7, w7, 150, 95, True)
    c.near(w7.volume, 0.75, "dragging to three quarters sets 0.75")
    _ = frame(u7, w7, 500, 95, True)
    c.near(w7.volume, 1.0, "dragging past the end clamps to the top")
    _ = frame(u7, w7, -50, 95, True)
    c.near(w7.volume, 0.0, "dragging past the start clamps to the bottom")
    _ = frame(u7, w7, 100, 95, True)
    _ = frame(u7, w7, 100, 95, False)
    c.near(w7.volume, 0.5, "release keeps the value")
    var focused = u7.focus
    _ = frame(u7, w7, 600, 600, False, KEY_RIGHT)
    c.near(w7.volume, 0.55, "Right on a focused slider is a step of a twentieth")
    c.eq(u7.focus, focused, "...and does not move focus")
    _ = frame(u7, w7, 600, 600, False, KEY_LEFT)
    _ = frame(u7, w7, 600, 600, False, KEY_LEFT)
    c.near(w7.volume, 0.45, "Left steps back")
    _ = frame(u7, w7, 600, 600, False, KEY_UP)
    c.ok(u7.focus != focused, "Up still moves focus away from a slider")

    # 6. The draw list: what a frame contains, and that its hash tracks every difference.
    var u8 = Ui(Theme.dark())
    var w8 = World()
    _ = frame(u8, w8, 600, 600, False)
    c.eq(u8.list.count(), 16, "an idle frame: 3 buttons x 3 + checkbox 4 + slider 3 commands")
    var fills = 0
    var strokes = 0
    var texts = 0
    for i in range(u8.list.count()):
        if u8.list.cmds[i].kind == CMD_FILL:
            fills += 1
        elif u8.list.cmds[i].kind == CMD_STROKE:
            strokes += 1
        elif u8.list.cmds[i].kind == CMD_TEXT:
            texts += 1
    c.eq(fills + strokes + texts, 16, "every command is a fill, a stroke or a text")
    c.eq(texts, 4, "four text runs: A, B, C and Music")
    var h_idle = u8.list.hash()
    var u9 = Ui(Theme.dark())
    var w9 = World()
    _ = frame(u9, w9, 600, 600, False)
    c.ok(u9.list.hash() == h_idle, "the same frame gives the same hash")
    var u10 = Ui(Theme.dark())
    var w10 = World()
    _ = frame(u10, w10, 10, 10, False)
    c.ok(u10.list.hash() != h_idle, "hovering a button changes the hash")
    var u11 = Ui(Theme.dark())
    var w11 = World()
    w11.music = True
    _ = frame(u11, w11, 600, 600, False)
    c.ok(u11.list.hash() != h_idle and u11.list.count() == 17, "a checked box adds a command and changes the hash")

    # 7. Text field: click focuses, typed code points insert at the caret, edit keys, UTF-8, Left / Right stay in the field.
    var tf = Ui(Theme.dark())
    var text = String("ab")
    var field = Rect(0, 0, 200, 24)
    var none = List[Int]()

    def tf_frame(mut ui: Ui, mut text: String, x: Float32, y: Float32, down: Bool, key: Int, typed: List[Int]):
        ui.begin_frame_typed(x, y, down, key, typed)
        text = ui.text_field(Rect(0, 0, 200, 24), text)

    tf_frame(tf, text, 10, 10, False, KEY_NONE, none)
    tf_frame(tf, text, 10, 10, True, KEY_NONE, none)
    tf_frame(tf, text, 10, 10, False, KEY_NONE, none)
    c.eq(tf.focus, 0, "a click focuses the text field")
    c.eq(tf.caret, 2, "...and puts the caret at the end")
    var typed = List[Int]()
    typed.append(0x63)
    tf_frame(tf, text, 600, 600, False, KEY_NONE, typed)
    c.ok(text == "abc" and tf.caret == 3, "typing c appends")
    tf_frame(tf, text, 600, 600, False, KEY_LEFT, none)
    tf_frame(tf, text, 600, 600, False, KEY_LEFT, none)
    c.eq(tf.caret, 1, "Left twice moves the caret and keeps focus in the field")
    c.eq(tf.focus, 0, "...focus did not move")
    var z = List[Int]()
    z.append(0x7A)
    tf_frame(tf, text, 600, 600, False, KEY_NONE, z)
    c.ok(text == "azbc" and tf.caret == 2, "typing z inserts at the caret")
    tf_frame(tf, text, 600, 600, False, KEY_BACKSPACE, none)
    c.ok(text == "abc" and tf.caret == 1, "Backspace removes the character before the caret")
    tf_frame(tf, text, 600, 600, False, KEY_DELETE, none)
    c.ok(text == "ac" and tf.caret == 1, "Delete removes the character at the caret")
    tf_frame(tf, text, 600, 600, False, KEY_HOME, none)
    tf_frame(tf, text, 600, 600, False, KEY_BACKSPACE, none)
    c.ok(text == "ac" and tf.caret == 0, "Backspace at the start does nothing")
    tf_frame(tf, text, 600, 600, False, KEY_END, none)
    c.eq(tf.caret, 2, "End moves the caret to the end")
    var cjk = List[Int]()
    cjk.append(0x4E2D)  # U+4E2D, 3 bytes in UTF-8
    cjk.append(0x6587)
    tf_frame(tf, text, 600, 600, False, KEY_NONE, cjk)
    c.ok(text == "ac中文" and tf.caret == 4, "CJK code points insert as whole characters")
    tf_frame(tf, text, 600, 600, False, KEY_BACKSPACE, none)
    c.ok(text == "ac中" and tf.caret == 3, "Backspace removes a whole 3-byte character")
    var ctl = List[Int]()
    ctl.append(0x07)
    ctl.append(0x7F)
    tf_frame(tf, text, 600, 600, False, KEY_NONE, ctl)
    c.ok(text == "ac中", "control characters are not inserted")
    var other = Ui(Theme.dark())
    var untouched = String("hi")
    tf_frame(other, untouched, 600, 600, False, KEY_NONE, z)
    c.ok(untouched == "hi", "an unfocused field ignores typed text")

    # 8. List box: click selects, Up / Down move the selection (and keep focus in the list), the view follows it.
    var lb = Ui(Theme.dark())
    var items = List[String]()
    for i in range(10):
        items.append("row " + String(i))
    var sel = -1
    var top = 0

    def lb_frame(mut ui: Ui, items: List[String], mut sel: Int, mut top: Int, x: Float32, y: Float32, down: Bool, key: Int):
        ui.begin_frame(x, y, down, key)
        sel = ui.list_box(Rect(0, 0, 100, 72), items, sel, top)  # 72 px / 24 px rows = 3 visible

    lb_frame(lb, items, sel, top, 10, 30, False, KEY_NONE)
    lb_frame(lb, items, sel, top, 10, 30, True, KEY_NONE)
    lb_frame(lb, items, sel, top, 10, 30, False, KEY_NONE)
    c.eq(sel, 1, "a click on the second row selects it")
    c.eq(lb.focus, 0, "...and focuses the list")
    lb_frame(lb, items, sel, top, 600, 600, False, KEY_DOWN)
    lb_frame(lb, items, sel, top, 600, 600, False, KEY_DOWN)
    c.eq(sel, 3, "Down twice selects row 3")
    c.eq(top, 1, "the view scrolled by one row to keep row 3 visible")
    c.eq(lb.focus, 0, "Down moved the selection, not the focus")
    lb_frame(lb, items, sel, top, 600, 600, False, KEY_END)
    c.ok(sel == 9 and top == 7, "End selects the last row and shows it")
    lb_frame(lb, items, sel, top, 600, 600, False, KEY_DOWN)
    c.eq(sel, 9, "Down at the last row stays")
    lb_frame(lb, items, sel, top, 600, 600, False, KEY_HOME)
    c.ok(sel == 0 and top == 0, "Home returns to the first row")
    lb_frame(lb, items, sel, top, 10, 60, False, KEY_NONE)
    lb_frame(lb, items, sel, top, 10, 60, True, KEY_NONE)
    c.eq(sel, 2, "with the view at the top, a click at y = 60 selects row 2")
    var empty = List[String]()
    var es = -1
    var et = 0
    lb_frame(lb, empty, es, et, 10, 10, True, KEY_NONE)
    c.ok(es == -1 and et == 0, "an empty list selects nothing")

    # 9. The wheel scrolls a list without changing its selection and clamps at both ends.
    var wl = Ui(Theme.dark())
    var wsel = 1
    var wtop = 0
    var no_keys = List[Int]()
    wl.begin_frame_input(10, 30, False, KEY_NONE, no_keys, 2)
    wsel = wl.list_box(Rect(0, 0, 100, 72), items, wsel, wtop)
    c.ok(wtop == 2 and wsel == 1, "two notches down scroll the view by two rows, the selection stays")
    wl.begin_frame_input(10, 30, False, KEY_NONE, no_keys, 50)
    wsel = wl.list_box(Rect(0, 0, 100, 72), items, wsel, wtop)
    c.eq(wtop, 7, "a long scroll clamps at the last full page (10 rows, 3 visible)")
    wl.begin_frame_input(10, 30, False, KEY_NONE, no_keys, -50)
    wsel = wl.list_box(Rect(0, 0, 100, 72), items, wsel, wtop)
    c.eq(wtop, 0, "...and at the top")
    wl.begin_frame_input(600, 600, False, KEY_NONE, no_keys, 3)
    wsel = wl.list_box(Rect(0, 0, 100, 72), items, wsel, wtop)
    c.eq(wtop, 0, "the wheel over another place does nothing to this list")

    print("ui_widgets:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("ui_widgets: " + String(c.failed) + " checks failed")
