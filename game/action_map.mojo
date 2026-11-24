"""Input actions by intent (ludens-engine #117). Format and rules: `docs/input.md`. Standard library only.

A game reads *actions* (`jump`, `move`, `look`), never keys. An action map is a text asset:

    ludens-actions 1
    action jump button buffer_ms=100
    action move stick deadzone=0.2 curve=1.5
    action look look
    bind jump key:Space
    bind jump pad:b0
    bind move.up key:KeyW
    bind move.x pad:a0
    bind move.y -pad:a1

Kinds: `button` (held, pressed, released; optional `buffer_ms`), `stick` (a 2-D value, x to the right, y up or forward) and
`look` (a 2-D camera turn in pixels). Sources (`device:code`), by physical position, so an AZERTY board that sends the
code of the key at W's place moves the same as QWERTY:

    key:KeyW  key:Space  key:ArrowUp   keyboard, by DOM `KeyboardEvent.code` name
    mouse:0                            mouse button (0 left, 1 right, 2 middle)
    mouse:drag0                        look only: pointer movement while that button is held
    pad:b0  pad:a0                     any gamepad: button, axis (W3C standard mapping, y is down)
    vpad:b0  vpad:a0                   the on-screen pad, same numbering
    -pad:a1                            a leading `-` negates an axis

Slots: a button has `main`; a stick has `up down left right` (digital) and `x y` (analog); a look has `main`.

Wire format: a keyboard key is its GLFW code (`InputState` key), a mouse button its index, an axis an `AXIS` event
(`InputState.get_axis(device, axis)`), and a gamepad button `b` of device `d` the key code `PAD_BUTTON_BASE + PAD_BUTTON_STRIDE * d + b`
(so a button press is a key edge with `is_key_just_pressed`). Devices 0 to 2 are gamepads, 3 is the on-screen pad.

Analog values of a stick go through a radial dead zone and a response curve: with m = |v| (the stick's length, 0..1),
m <= deadzone gives 0, otherwise ((m - deadzone) / (1 - deadzone))^curve, in the direction of v. Digital keys give the
unit steps (-1, 0, 1) as they always did (two keys held is (1, 1), not normalised) and the larger of the digital and
the analog vector is used. `Rebinding`: `rebind` refuses a source another slot holds unless told to take it from there.
A profile (`ludens-profile 1`, `set <action>.<slot> <sources...>` rows) is the bindings a player changed; `load_profile`
puts them over the defaults."""
from std.math import sqrt, pow

comptime KIND_BUTTON = 0
comptime KIND_STICK = 1
comptime KIND_LOOK = 2

comptime DEV_KEY = 0
comptime DEV_MOUSE = 1
comptime DEV_PAD = 2
comptime DEV_VPAD = 3

comptime SLOT_MAIN = 0
comptime SLOT_UP = 1
comptime SLOT_DOWN = 2
comptime SLOT_LEFT = 3
comptime SLOT_RIGHT = 4
comptime SLOT_X = 5
comptime SLOT_Y = 6

comptime MAX_KEYS = 512
comptime MAX_MOUSE = 8
comptime GAMEPADS = 3  # devices 0..2; device 3 is the on-screen pad
comptime VPAD_DEVICE = 3
comptime AXIS_DEVICES = 4
comptime MAX_AXES = 8
comptime PAD_BUTTON_BASE = 400
comptime PAD_BUTTON_STRIDE = 20  # buttons per device: 400 + 20 * 3 + 19 = 479 < MAX_KEYS
comptime BUTTON_AXIS_THRESHOLD = 0.5  # an axis bound to a button counts as held past this
comptime PROFILE_HEADER = "ludens-profile 1"
comptime MAP_HEADER = "ludens-actions 1"


def pad_button_key(device: Int, button: Int) -> Int:
    """The key code a gamepad (or on-screen pad) button is sent as."""
    return PAD_BUTTON_BASE + PAD_BUTTON_STRIDE * device + button


def key_code(name: String) -> Int:
    """The GLFW code of a DOM `KeyboardEvent.code` name, or -1. Same table as shell/web/keys.ts."""
    if name == "Space":
        return 32
    if name == "Escape":
        return 256
    if name == "Enter":
        return 257
    if name == "Tab":
        return 258
    if name == "Backspace":
        return 259
    if name == "ArrowRight":
        return 262
    if name == "ArrowLeft":
        return 263
    if name == "ArrowDown":
        return 264
    if name == "ArrowUp":
        return 265
    if name == "F2":
        return 291
    if name == "ShiftLeft":
        return 340
    if name == "ControlLeft":
        return 341
    if name == "AltLeft":
        return 342
    var b = name.as_bytes()
    if len(b) == 4 and name.startswith("Key") and Int(b[3]) >= 65 and Int(b[3]) <= 90:
        return Int(b[3])
    if len(b) == 6 and name.startswith("Digit") and Int(b[5]) >= 48 and Int(b[5]) <= 57:
        return Int(b[5])
    return -1


def key_name(code: Int) -> String:
    """The inverse of `key_code`; "" for a code with no name."""
    if code == 32:
        return "Space"
    if code == 256:
        return "Escape"
    if code == 257:
        return "Enter"
    if code == 258:
        return "Tab"
    if code == 259:
        return "Backspace"
    if code == 262:
        return "ArrowRight"
    if code == 263:
        return "ArrowLeft"
    if code == 264:
        return "ArrowDown"
    if code == 265:
        return "ArrowUp"
    if code == 291:
        return "F2"
    if code == 340:
        return "ShiftLeft"
    if code == 341:
        return "ControlLeft"
    if code == 342:
        return "AltLeft"
    if code >= 65 and code <= 90:
        return "Key" + chr(code)
    if code >= 48 and code <= 57:
        return "Digit" + chr(code)
    return ""


def slot_name(kind: Int, slot: Int) -> String:
    if slot == SLOT_UP:
        return "up"
    if slot == SLOT_DOWN:
        return "down"
    if slot == SLOT_LEFT:
        return "left"
    if slot == SLOT_RIGHT:
        return "right"
    if slot == SLOT_X:
        return "x"
    if slot == SLOT_Y:
        return "y"
    return "main"


def slot_of(kind: Int, name: String) -> Int:
    """The slot called `name` on an action of `kind`, or -1."""
    if kind == KIND_STICK:
        if name == "up":
            return SLOT_UP
        if name == "down":
            return SLOT_DOWN
        if name == "left":
            return SLOT_LEFT
        if name == "right":
            return SLOT_RIGHT
        if name == "x":
            return SLOT_X
        if name == "y":
            return SLOT_Y
        return -1
    return SLOT_MAIN if name == "main" else -1


def _parse_int(s: String) -> Int:
    """A non-negative decimal, or -1."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > 6:
        return -1
    var v = 0
    for i in range(len(b)):
        if Int(b[i]) < 48 or Int(b[i]) > 57:
            return -1
        v = v * 10 + Int(b[i]) - 48
    return v


@fieldwise_init
struct Binding(Copyable, ImplicitlyCopyable, Movable):
    """One source: a device, a code (key code, mouse button, pad button or axis index), whether it is an axis (or a
    pointer drag), and the sign an axis is multiplied by."""
    var device: Int
    var code: Int
    var analog: Bool
    var sign: Int

    def same_source(self, o: Binding) -> Bool:
        """The same physical control (a negated axis is the same control)."""
        return self.device == o.device and self.code == o.code and self.analog == o.analog

    def source(self) -> String:
        """The text form: `key:KeyW`, `-pad:a1`."""
        var s = String()
        if self.sign < 0:
            s += "-"
        if self.device == DEV_KEY:
            return s + "key:" + key_name(self.code)
        if self.device == DEV_MOUSE:
            return s + ("mouse:drag" if self.analog else "mouse:") + String(self.code)
        var dev = "pad:" if self.device == DEV_PAD else "vpad:"
        return s + dev + ("a" if self.analog else "b") + String(self.code)


def parse_source(text: String) raises -> Binding:
    """`key:KeyW`, `mouse:0`, `mouse:drag0`, `pad:b0`, `pad:a1`, `vpad:b0`, with an optional leading `-`. Raises for anything else."""
    var s = text
    var sign = 1
    if s.startswith("-"):
        sign = -1
        var tail = String(s[byte=1:])
        s = tail
    var colon = s.find(":")
    if colon < 0:
        raise Error("`" + text + "` is not a source: expected device:code, for example key:KeyW")
    var dev = String(s[byte=:colon])
    var rest = String(s[byte = colon + 1 :])
    if dev == "key":
        var c = key_code(rest)
        if c < 0:
            raise Error("`" + rest + "` is not a key name; use a DOM KeyboardEvent.code such as KeyW, Space, ArrowUp")
        if sign < 0:
            raise Error("`" + text + "`: only an axis can be negated")
        return Binding(DEV_KEY, c, False, 1)
    if dev == "mouse":
        if sign < 0:
            raise Error("`" + text + "`: only an axis can be negated")
        if rest.startswith("drag"):
            var d = _parse_int(String(rest[byte=4:]))
            if d < 0 or d >= MAX_MOUSE:
                raise Error("`" + text + "`: no such mouse button")
            return Binding(DEV_MOUSE, d, True, 1)
        var m = _parse_int(rest)
        if m < 0 or m >= MAX_MOUSE:
            raise Error("`" + text + "`: no such mouse button")
        return Binding(DEV_MOUSE, m, False, 1)
    if dev == "pad" or dev == "vpad":
        var device = DEV_PAD if dev == "pad" else DEV_VPAD
        if rest.byte_length() < 2:
            raise Error("`" + text + "`: expected b<number> (button) or a<number> (axis)")
        var kind = String(rest[byte=:1])
        var n = _parse_int(String(rest[byte=1:]))
        if kind == "b":
            if n < 0 or n >= PAD_BUTTON_STRIDE:
                raise Error("`" + text + "`: a pad has buttons 0 to " + String(PAD_BUTTON_STRIDE - 1))
            if sign < 0:
                raise Error("`" + text + "`: only an axis can be negated")
            return Binding(device, n, False, 1)
        if kind == "a":
            if n < 0 or n >= MAX_AXES:
                raise Error("`" + text + "`: a pad has axes 0 to " + String(MAX_AXES - 1))
            return Binding(device, n, True, sign)
        raise Error("`" + text + "`: expected b<number> (button) or a<number> (axis)")
    raise Error("`" + text + "`: unknown device `" + dev + "`; use key, mouse, pad or vpad")


@fieldwise_init
struct SlotBinding(Copyable, ImplicitlyCopyable, Movable):
    var slot: Int
    var b: Binding


struct InputFrame(Copyable, Movable):
    """What the devices did this frame, with no device library in the way: `app/controls.read_frame` fills it from
    `InputState`, a test fills it by hand."""
    var down: List[Bool]  # key codes held (gamepad buttons included, as PAD_BUTTON_BASE codes)
    var edge: List[Bool]  # key codes that went down this frame
    var mouse_down: List[Bool]
    var mouse_edge: List[Bool]
    var axes: List[Float64]  # AXIS_DEVICES * MAX_AXES
    var mouse_dx: Float64
    var mouse_dy: Float64

    def __init__(out self):
        self.down = List[Bool](length=MAX_KEYS, fill=False)
        self.edge = List[Bool](length=MAX_KEYS, fill=False)
        self.mouse_down = List[Bool](length=MAX_MOUSE, fill=False)
        self.mouse_edge = List[Bool](length=MAX_MOUSE, fill=False)
        self.axes = List[Float64](length=AXIS_DEVICES * MAX_AXES, fill=0.0)
        self.mouse_dx = 0.0
        self.mouse_dy = 0.0

    def press(mut self, key: Int):
        """Held, and went down this frame."""
        if key >= 0 and key < MAX_KEYS:
            self.down[key] = True
            self.edge[key] = True

    def hold(mut self, key: Int):
        """Held since an earlier frame."""
        if key >= 0 and key < MAX_KEYS:
            self.down[key] = True

    def tap(mut self, key: Int):
        """Down and up inside the frame: an edge, not held."""
        if key >= 0 and key < MAX_KEYS:
            self.edge[key] = True

    def set_axis(mut self, device: Int, axis: Int, v: Float64):
        if device >= 0 and device < AXIS_DEVICES and axis >= 0 and axis < MAX_AXES:
            self.axes[device * MAX_AXES + axis] = v

    def axis(self, device: Int, axis: Int) -> Float64:
        if device < 0 or device >= AXIS_DEVICES or axis < 0 or axis >= MAX_AXES:
            return 0.0
        return self.axes[device * MAX_AXES + axis]


struct Action(Copyable, Movable):
    var name: String
    var kind: Int
    var deadzone: Float64  # stick only: fraction of full travel that reads as zero
    var curve: Float64  # stick only: exponent applied to the length after the dead zone (1 = linear)
    var buffer_ms: Float64  # button only: how long a press stays pending for the game
    var bindings: List[SlotBinding]
    var defaults: List[SlotBinding]
    # this frame
    var down: Bool
    var pressed: Bool
    var released: Bool
    var x: Float64
    var y: Float64

    def __init__(out self, name: String, kind: Int):
        self.name = name
        self.kind = kind
        self.deadzone = 0.0
        self.curve = 1.0
        self.buffer_ms = 0.0
        self.bindings = List[SlotBinding]()
        self.defaults = List[SlotBinding]()
        self.down = False
        self.pressed = False
        self.released = False
        self.x = 0.0
        self.y = 0.0


def shape_stick(x: Float64, y: Float64, deadzone: Float64, curve: Float64) -> Tuple[Float64, Float64]:
    """Radial dead zone and response curve of an analog vector (length 0..1 is full travel; longer is clamped to 1)."""
    var m = sqrt(x * x + y * y)
    if m <= deadzone or m == 0.0:
        return (0.0, 0.0)
    if m > 1.0:
        m = 1.0
    var span = 1.0 - deadzone
    var t = (m - deadzone) / span if span > 0.0 else 1.0
    var out = pow(t, curve) if curve != 1.0 else t
    var len = sqrt(x * x + y * y)
    return (x / len * out, y / len * out)


struct ActionMap(Copyable, Movable):
    var actions: List[Action]
    var primed: Bool  # the first pointer event reports a move from (0, 0); it is not a camera turn
    var key_labels: List[String]  # layout labels: "KeyW=Z" pairs a shell can fill from the keyboard layout map
    var _prev_axis_down: List[Bool]  # per action: the last frame's held state, for axis-bound buttons

    def __init__(out self):
        self.actions = List[Action]()
        self.primed = False
        self.key_labels = List[String]()
        self._prev_axis_down = List[Bool]()

    # ------------------------------------------------------------------ lookup
    def index(self, name: String) -> Int:
        for i in range(len(self.actions)):
            if self.actions[i].name == name:
                return i
        return -1

    def down(self, name: String) -> Bool:
        var i = self.index(name)
        return i >= 0 and self.actions[i].down

    def pressed(self, name: String) -> Bool:
        var i = self.index(name)
        return i >= 0 and self.actions[i].pressed

    def released(self, name: String) -> Bool:
        var i = self.index(name)
        return i >= 0 and self.actions[i].released

    def x(self, name: String) -> Float64:
        var i = self.index(name)
        return self.actions[i].x if i >= 0 else 0.0

    def y(self, name: String) -> Float64:
        var i = self.index(name)
        return self.actions[i].y if i >= 0 else 0.0

    def buffer_ms(self, name: String) -> Float64:
        var i = self.index(name)
        return self.actions[i].buffer_ms if i >= 0 else 0.0

    # ------------------------------------------------------------------ per frame
    def _held(self, b: Binding, f: InputFrame) -> Bool:
        if b.device == DEV_KEY:
            return f.down[b.code]
        if b.device == DEV_MOUSE:
            return f.mouse_down[b.code]
        var dev = 0 if b.device == DEV_PAD else VPAD_DEVICE
        if b.analog:
            return self._analog(b, f) > BUTTON_AXIS_THRESHOLD  # any gamepad, like a stick's axis
        return f.down[pad_button_key(dev, b.code)] or (b.device == DEV_PAD and _any_pad_button(f, b.code))

    def _edge(self, b: Binding, f: InputFrame) -> Bool:
        if b.device == DEV_KEY:
            return f.edge[b.code]
        if b.device == DEV_MOUSE:
            return f.mouse_edge[b.code]
        if b.analog:
            return False  # an axis edge needs last frame's value; `update` derives it from `down`
        var dev = 0 if b.device == DEV_PAD else VPAD_DEVICE
        if f.edge[pad_button_key(dev, b.code)]:
            return True
        if b.device == DEV_PAD:
            for d in range(1, GAMEPADS):
                if f.edge[pad_button_key(d, b.code)]:
                    return True
        return False

    def _analog(self, b: Binding, f: InputFrame) -> Float64:
        """The value of an axis binding: the largest in magnitude over the gamepads for `pad`, signed."""
        if b.device == DEV_VPAD:
            return Float64(b.sign) * f.axis(VPAD_DEVICE, b.code)
        var best = 0.0
        for d in range(GAMEPADS):
            var v = f.axis(d, b.code)
            if abs(v) > abs(best):
                best = v
        return Float64(b.sign) * best

    def update(mut self, f: InputFrame):
        """Evaluate every action against this frame's input."""
        while len(self._prev_axis_down) < len(self.actions):
            self._prev_axis_down.append(False)
        for i in range(len(self.actions)):
            var kind = self.actions[i].kind
            if kind == KIND_BUTTON:
                var held = False
                var edge = False
                var axis_held = False
                for s in range(len(self.actions[i].bindings)):
                    var b = self.actions[i].bindings[s].b
                    if self._held(b, f):
                        held = True
                        if b.analog:
                            axis_held = True
                    if self._edge(b, f):
                        edge = True
                var was = self.actions[i].down
                if axis_held and not self._prev_axis_down[i] and not was:
                    edge = True
                self._prev_axis_down[i] = axis_held
                self.actions[i].pressed = edge or (held and not was)
                self.actions[i].released = was and not held
                self.actions[i].down = held
                self.actions[i].x = 1.0 if held else 0.0
            elif kind == KIND_STICK:
                var up = False
                var dn = False
                var lf = False
                var rt = False
                var ax = 0.0
                var ay = 0.0
                for s in range(len(self.actions[i].bindings)):
                    var sb = self.actions[i].bindings[s]
                    if sb.slot == SLOT_X:
                        var v = self._analog(sb.b, f)
                        if abs(v) > abs(ax):
                            ax = v
                    elif sb.slot == SLOT_Y:
                        var v = self._analog(sb.b, f)
                        if abs(v) > abs(ay):
                            ay = v
                    elif self._held(sb.b, f):
                        if sb.slot == SLOT_UP:
                            up = True
                        elif sb.slot == SLOT_DOWN:
                            dn = True
                        elif sb.slot == SLOT_LEFT:
                            lf = True
                        elif sb.slot == SLOT_RIGHT:
                            rt = True
                var dx = (1.0 if rt else 0.0) - (1.0 if lf else 0.0)
                var dy = (1.0 if up else 0.0) - (1.0 if dn else 0.0)
                var shaped = shape_stick(ax, ay, self.actions[i].deadzone, self.actions[i].curve)
                var dm = dx * dx + dy * dy
                var am = shaped[0] * shaped[0] + shaped[1] * shaped[1]
                if am > dm:
                    self.actions[i].x = shaped[0]
                    self.actions[i].y = shaped[1]
                else:
                    self.actions[i].x = dx
                    self.actions[i].y = dy
                self.actions[i].down = self.actions[i].x != 0.0 or self.actions[i].y != 0.0
                self.actions[i].pressed = False
                self.actions[i].released = False
            else:
                var drag = False
                for s in range(len(self.actions[i].bindings)):
                    var b = self.actions[i].bindings[s].b
                    if b.device == DEV_MOUSE and b.analog and f.mouse_down[b.code]:
                        drag = True
                if self.primed and drag:
                    self.actions[i].x = f.mouse_dx
                    self.actions[i].y = f.mouse_dy
                else:
                    self.actions[i].x = 0.0
                    self.actions[i].y = 0.0
        if f.mouse_dx != 0.0 or f.mouse_dy != 0.0:
            self.primed = True

    def release_all(mut self):
        """Focus was lost: nothing is held any more."""
        for i in range(len(self.actions)):
            self.actions[i].down = False
            self.actions[i].pressed = False
            self.actions[i].released = False
            self.actions[i].x = 0.0
            self.actions[i].y = 0.0

    # ------------------------------------------------------------------ parsing
    @staticmethod
    def parse(text: String) raises -> ActionMap:
        """Parse an action map. Every error names the line: `demo.actions:7: ...` (the caller prefixes the file name)."""
        var m = ActionMap()
        var lines = text.split("\n")
        var first = True
        for n in range(len(lines)):
            var line = String(lines[n].strip())
            var hash = line.find("#")
            if hash >= 0:
                line = String(String(line[byte=:hash]).strip())
            if line.byte_length() == 0:
                continue
            var ln = String(n + 1)
            if first:
                first = False
                if line != MAP_HEADER:
                    raise Error(ln + ": the first row must be `" + MAP_HEADER + "`")
                continue
            var w = List[String]()
            for p in line.split():
                w.append(String(p))
            if w[0] == "action":
                if len(w) < 3:
                    raise Error(ln + ": expected `action <name> <button|stick|look> [key=value ...]`")
                if m.index(w[1]) >= 0:
                    raise Error(ln + ": action `" + w[1] + "` is defined twice")
                var kind = -1
                if w[2] == "button":
                    kind = KIND_BUTTON
                elif w[2] == "stick":
                    kind = KIND_STICK
                elif w[2] == "look":
                    kind = KIND_LOOK
                else:
                    raise Error(ln + ": the kind of `" + w[1] + "` is `" + w[2] + "`; use button, stick or look")
                var a = Action(w[1], kind)
                for k in range(3, len(w)):
                    var eq = w[k].find("=")
                    if eq < 0:
                        raise Error(ln + ": `" + w[k] + "` is not key=value")
                    var key = String(w[k][byte=:eq])
                    var val = String(w[k][byte = eq + 1 :])
                    var f = Float64(0)
                    try:
                        f = Float64(val)
                    except:
                        raise Error(ln + ": `" + val + "` is not a number")
                    if key == "deadzone" and kind == KIND_STICK:
                        if f < 0.0 or f >= 1.0:
                            raise Error(ln + ": deadzone is 0 up to (not including) 1")
                        a.deadzone = f
                    elif key == "curve" and kind == KIND_STICK:
                        if f <= 0.0:
                            raise Error(ln + ": curve is an exponent above 0")
                        a.curve = f
                    elif key == "buffer_ms" and kind == KIND_BUTTON:
                        if f < 0.0 or f > 1000.0:
                            raise Error(ln + ": buffer_ms is 0 to 1000")
                        a.buffer_ms = f
                    else:
                        raise Error(ln + ": `" + key + "` is not an attribute of a " + w[2])
                m.actions.append(a^)
            elif w[0] == "bind":
                if len(w) != 3:
                    raise Error(ln + ": expected `bind <action>[.<slot>] <source>`")
                var dot = w[1].find(".")
                var an = w[1] if dot < 0 else String(w[1][byte=:dot])
                var ai = m.index(an)
                if ai < 0:
                    raise Error(ln + ": `" + an + "` is not an action; define it with `action` above")
                var sn = "main" if dot < 0 else String(w[1][byte = dot + 1 :])
                var slot = slot_of(m.actions[ai].kind, sn)
                if slot < 0:
                    raise Error(ln + ": `" + sn + "` is not a slot of `" + an + "`")
                var b = Binding(0, 0, False, 1)
                try:
                    b = parse_source(w[2])
                except e:
                    raise Error(ln + ": " + String(e))
                m._check_fits(ai, slot, b, ln)
                m.actions[ai].bindings.append(SlotBinding(slot, b))
            else:
                raise Error(ln + ": `" + w[0] + "` is not `action` or `bind`")
        if first:
            raise Error("empty: the first row must be `" + MAP_HEADER + "`")
        for i in range(len(m.actions)):
            m.actions[i].defaults = m.actions[i].bindings.copy()
        return m^

    def _check_fits(self, ai: Int, slot: Int, b: Binding, ln: String) raises:
        """A source must suit its slot: digital slots take buttons and keys, `x` / `y` take axes, `look` takes a drag, a
        button takes a digital source or an axis."""
        var kind = self.actions[ai].kind
        if kind == KIND_STICK:
            if (slot == SLOT_X or slot == SLOT_Y) and not b.analog:
                raise Error(ln + ": slot `" + slot_name(kind, slot) + "` takes an axis (pad:a0), not `" + b.source() + "`")
            if slot != SLOT_X and slot != SLOT_Y and b.analog:
                raise Error(ln + ": slot `" + slot_name(kind, slot) + "` takes a key or button, not `" + b.source() + "`")
        elif kind == KIND_LOOK:
            if not (b.device == DEV_MOUSE and b.analog):
                raise Error(ln + ": a look action takes mouse:drag<n>, not `" + b.source() + "`")
        else:
            if b.device == DEV_MOUSE and b.analog:
                raise Error(ln + ": mouse:drag is for a look action")

    # ------------------------------------------------------------------ rebinding
    def conflicts(self, action: String, slot: Int, b: Binding) -> List[String]:
        """The `action.slot` names (other than `action.slot` itself) that already use the control `b`."""
        var out = List[String]()
        var ai = self.index(action)
        for i in range(len(self.actions)):
            for s in range(len(self.actions[i].bindings)):
                var sb = self.actions[i].bindings[s]
                if i == ai and sb.slot == slot:
                    continue
                if sb.b.same_source(b):
                    var nm = self.actions[i].name + "." + slot_name(self.actions[i].kind, sb.slot)
                    var seen = False
                    for k in range(len(out)):
                        if out[k] == nm:
                            seen = True
                    if not seen:
                        out.append(nm)
        return out^

    def rebind(mut self, action: String, slot: Int, b: Binding, take: Bool = False) raises -> List[String]:
        """Bind the control `b` to `action.slot`, replacing what that slot had on the same device. Returns the
        slots that already used `b`: with `take` False nothing changes and the list says why; with `take` True the
        control is removed from them and bound here. An empty list means the binding was applied (and nothing else changed)."""
        var ai = self.index(action)
        if ai < 0:
            raise Error("no action `" + action + "`")
        self._check_fits(ai, slot, b, "rebind")
        var clash = self.conflicts(action, slot, b)
        if len(clash) > 0 and not take:
            return clash^
        for i in range(len(self.actions)):
            var kept = List[SlotBinding]()
            for s in range(len(self.actions[i].bindings)):
                var sb = self.actions[i].bindings[s]
                var drop = False
                if i == ai and sb.slot == slot and sb.b.device == b.device:
                    drop = True
                if sb.b.same_source(b) and not (i == ai and sb.slot == slot):
                    drop = True
                if not drop:
                    kept.append(sb)
            self.actions[i].bindings = kept^
        self.actions[ai].bindings.append(SlotBinding(slot, b))
        return List[String]()

    def reset(mut self):
        """Every action back to its default bindings."""
        for i in range(len(self.actions)):
            self.actions[i].bindings = self.actions[i].defaults.copy()

    # ------------------------------------------------------------------ profile
    def profile(self) -> String:
        """The slots whose bindings differ from the defaults, as a profile file. A map still on its defaults gives the header alone."""
        var out = String(PROFILE_HEADER) + "\n"
        for i in range(len(self.actions)):
            var slots = List[Int]()
            for s in range(len(self.actions[i].bindings)):
                _add_slot(slots, self.actions[i].bindings[s].slot)
            for s in range(len(self.actions[i].defaults)):
                _add_slot(slots, self.actions[i].defaults[s].slot)
            for si in range(len(slots)):
                var now = _sources(self.actions[i].bindings, slots[si])
                var was = _sources(self.actions[i].defaults, slots[si])
                if now != was:
                    var line = "set " + self.actions[i].name + "." + slot_name(self.actions[i].kind, slots[si])
                    for k in range(len(now)):
                        line += " " + now[k]
                    out += line + "\n"
        return out^

    def load_profile(mut self, text: String) -> List[String]:
        """Put a profile over the current bindings. A row that is wrong (unknown action, slot or source) is skipped and named in
        the result; the rows before and after it still apply. Every good row is applied first and conflicts are looked for after:
        a profile saved after `rebind(..., take=True)` has a row that takes a control from a slot whose own row comes later, and
        the two rows are only consistent together. A control that two slots end up holding is given back: a slot the profile
        did not set wins over one it did, and of two profile rows the later loses (its slot returns to its bindings from before the
        load); the row is named in the result."""
        var problems = List[String]()
        var lines = text.split("\n")
        var first = True
        var before = List[List[SlotBinding]]()
        for i in range(len(self.actions)):
            before.append(self.actions[i].bindings.copy())
        var set_action = List[Int]()  # the profile rows that were applied: action index, slot, line number
        var set_slot = List[Int]()
        var set_line = List[String]()
        for n in range(len(lines)):
            var line = String(lines[n].strip())
            if line.byte_length() == 0 or line.startswith("#"):
                continue
            var ln = String(n + 1)
            if first:
                first = False
                if line != PROFILE_HEADER:
                    problems.append(ln + ": the first row must be `" + PROFILE_HEADER + "`")
                    return problems^
                continue
            var w = List[String]()
            for p in line.split():
                w.append(String(p))
            if w[0] != "set" or len(w) < 2:
                problems.append(ln + ": expected `set <action>.<slot> <sources...>`")
                continue
            var dot = w[1].find(".")
            var an = w[1] if dot < 0 else String(w[1][byte=:dot])
            var ai = self.index(an)
            if ai < 0:
                problems.append(ln + ": no action `" + an + "`")
                continue
            var sn = "main" if dot < 0 else String(w[1][byte = dot + 1 :])
            var slot = slot_of(self.actions[ai].kind, sn)
            if slot < 0:
                problems.append(ln + ": no slot `" + sn + "` on `" + an + "`")
                continue
            var parsed = List[Binding]()
            var bad = False
            for k in range(2, len(w)):
                try:
                    var b = parse_source(w[k])
                    self._check_fits(ai, slot, b, ln)
                    parsed.append(b)
                except e:
                    problems.append(ln + ": " + String(e))
                    bad = True
                    break
            if bad:
                continue
            var kept = List[SlotBinding]()
            for s in range(len(self.actions[ai].bindings)):
                if self.actions[ai].bindings[s].slot != slot:
                    kept.append(self.actions[ai].bindings[s])
            for k in range(len(parsed)):
                kept.append(SlotBinding(slot, parsed[k]))
            self.actions[ai].bindings = kept^
            set_action.append(ai)
            set_slot.append(slot)
            set_line.append(ln)
        # give back what two slots hold at once (at most one pass per applied row: each pass reverts one row)
        for _ in range(len(set_action) + 1):
            var found = False
            var a1 = 0
            var s1 = 0
            var a2 = 0
            var s2 = 0
            var shared = String()
            for i in range(len(self.actions)):
                for x in range(len(self.actions[i].bindings)):
                    for j in range(i, len(self.actions)):
                        for y in range(len(self.actions[j].bindings)):
                            var bx = self.actions[i].bindings[x]
                            var by = self.actions[j].bindings[y]
                            if bx.slot == by.slot and i == j:
                                continue
                            if not found and bx.b.same_source(by.b):
                                found = True
                                a1 = i
                                s1 = bx.slot
                                a2 = j
                                s2 = by.slot
                                shared = bx.b.source()
            if not found:
                break
            var row1 = -1
            var row2 = -1
            for r in range(len(set_action)):
                if set_action[r] == a1 and set_slot[r] == s1:
                    row1 = r
                if set_action[r] == a2 and set_slot[r] == s2:
                    row2 = r
            var loser = row1 if row1 >= row2 else row2  # a slot the profile did not set (-1) never loses; of two rows the later does
            if loser < 0:
                break  # a conflict that was there before the load: not this profile's
            var la = set_action[loser]
            var ls = set_slot[loser]
            var other = self.actions[a2].name + "." + slot_name(self.actions[a2].kind, s2) if loser == row1 else self.actions[a1].name + "." + slot_name(self.actions[a1].kind, s1)
            problems.append(set_line[loser] + ": `" + shared + "` is already used by " + other)
            var back = List[SlotBinding]()
            for s in range(len(self.actions[la].bindings)):
                if self.actions[la].bindings[s].slot != ls:
                    back.append(self.actions[la].bindings[s])
            for s in range(len(before[la])):
                if before[la][s].slot == ls:
                    back.append(before[la][s])
            self.actions[la].bindings = back^
            set_action[loser] = -1  # this row is spent
            set_slot[loser] = -1
        return problems^

    # ------------------------------------------------------------------ prompts
    def prompt_source(self, action: String, slot: Int, device: Int) -> String:
        """The text key of the label to show for `action.slot` on `device` (DEV_KEY, DEV_MOUSE, DEV_PAD, DEV_VPAD), or
        "" when it has no binding there. The label text is in a string table (`game/input_strings.mojo`): `input.key.space`,
        `input.pad.b0`."""
        var ai = self.index(action)
        if ai < 0:
            return ""
        for s in range(len(self.actions[ai].bindings)):
            var sb = self.actions[ai].bindings[s]
            if sb.slot == slot and sb.b.device == device:
                return label_key(sb.b)
        return ""

    def has_binding(self, action: String, slot: Int, device: Int) -> Bool:
        return self.prompt_source(action, slot, device).byte_length() > 0


def label_key(b: Binding) -> String:
    """The string-table key of a source's display name, e.g. `input.key.space`, `input.key.key_w`, `input.pad.b0`."""
    if b.device == DEV_KEY:
        var n = key_name(b.code)
        var out = String()
        var bytes = n.as_bytes()
        for i in range(len(bytes)):
            var c = Int(bytes[i])
            if c >= 65 and c <= 90:
                if i > 0:
                    out += "_"
                out += chr(c + 32)
            else:
                out += chr(c)
        return "input.key." + out
    if b.device == DEV_MOUSE:
        return "input.mouse." + ("drag" if b.analog else "b") + String(b.code)
    var dev = "pad" if b.device == DEV_PAD else "vpad"
    return "input." + dev + "." + ("a" if b.analog else "b") + String(b.code) + ("n" if b.sign < 0 else "")


def _any_pad_button(f: InputFrame, button: Int) -> Bool:
    for d in range(GAMEPADS):
        if f.down[pad_button_key(d, button)]:
            return True
    return False


def _add_slot(mut slots: List[Int], s: Int):
    for i in range(len(slots)):
        if slots[i] == s:
            return
    slots.append(s)


def _sources(bs: List[SlotBinding], slot: Int) -> List[String]:
    """The sources bound to `slot`, in alphabetical order: the order they were added in is not part of what a profile says."""
    var out = List[String]()
    for i in range(len(bs)):
        if bs[i].slot == slot:
            out.append(bs[i].b.source())
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            var t = out[j - 1]
            out[j - 1] = out[j]
            out[j] = t
            j -= 1
    return out^


struct InputBuffer(Copyable, Movable):
    """A press that stays pending after the frame it came in, for `window_ms`, so a jump pressed 100 ms before landing
    still fires. The game owns one per buffered action: `press(window)` when `Intent.jump` arrives, `take()` at every
    point where the action could act (it clears the press and answers once), `age(dt_ms)` once per frame after that.
    With a window of 0 the press is pending for its own frame only."""
    var left_ms: Float64
    var fresh: Bool  # pressed in the frame being stepped

    def __init__(out self):
        self.left_ms = 0.0
        self.fresh = False

    def press(mut self, window_ms: Float64):
        self.left_ms = window_ms if window_ms > 0.0 else 0.0
        self.fresh = True

    def live(self) -> Bool:
        return self.fresh or self.left_ms > 0.0

    def age(mut self, dt_ms: Float64):
        self.fresh = False
        self.left_ms = self.left_ms - dt_ms if self.left_ms > dt_ms else 0.0

    def take(mut self) -> Bool:
        """True once per press, while it is pending."""
        if self.live():
            self.left_ms = 0.0
            self.fresh = False
            return True
        return False
