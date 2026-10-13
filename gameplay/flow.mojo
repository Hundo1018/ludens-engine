"""Game flow: a state stack and world flags (ROADMAP 17.72).

`FlowStack` formalises "the caller skips frame_dt to pause": each state
declares which subsystems tick (`TICK_SIM`, `TICK_TIMERS`, `TICK_EVENTS`,
bit mask); the top of the stack decides. Pause is a push, resume a pop, so
nested pauses (a menu over a pause) unwind in order.

`Flags` is the world / session blackboard: named integer, boolean or
fixed-point values (`FLAG_INT`, `FLAG_BOOL`, `FLAG_FX` in 1/1000). A set
that changes the value appends the flag's index to `changed` (drained by
the caller, e.g. objectives listening for flag events). `to_bytes` /
`from_bytes` carry names and kinds; loading a flag whose kind changed
raises (a save from a build where the flag meant something else).
"""

comptime TICK_SIM = 1
comptime TICK_TIMERS = 2
comptime TICK_EVENTS = 4
comptime TICK_ALL = 7

comptime FLAG_INT = 0
comptime FLAG_BOOL = 1
comptime FLAG_FX = 2


@fieldwise_init
struct FlowState(Copyable, ImplicitlyCopyable, Movable):
    var id: Int
    var ticks: Int  # TICK_* mask


struct FlowStack(Copyable, Movable):
    var stack: List[FlowState]

    def __init__(out self):
        self.stack = List[FlowState]()

    def push(mut self, id: Int, ticks: Int):
        self.stack.append(FlowState(id, ticks))

    def pop(mut self) raises -> FlowState:
        if len(self.stack) == 0:
            raise Error("FlowStack.pop: empty")
        return self.stack.pop()

    def top(self) -> Int:
        return self.stack[len(self.stack) - 1].id if len(self.stack) > 0 else -1

    def ticks(self, what: Int) -> Bool:
        """Whether the subsystem `what` ticks under the current top state."""
        if len(self.stack) == 0:
            return False
        return (self.stack[len(self.stack) - 1].ticks & what) != 0

    def depth(self) -> Int:
        return len(self.stack)


struct Flags(Copyable, Movable):
    var names: List[String]
    var kinds: List[Int]
    var values: List[Int]
    var changed: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.kinds = List[Int]()
        self.values = List[Int]()
        self.changed = List[Int]()

    def find(self, name: String) -> Int:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return i
        return -1

    def declare(mut self, name: String, kind: Int, initial: Int = 0) raises -> Int:
        var i = self.find(name)
        if i >= 0:
            if self.kinds[i] != kind:
                raise Error("Flags.declare: '" + name + "' already declared with another kind")
            return i
        self.names.append(name)
        self.kinds.append(kind)
        self.values.append(initial)
        return len(self.names) - 1

    def set(mut self, i: Int, v: Int):
        var nv = (1 if v != 0 else 0) if self.kinds[i] == FLAG_BOOL else v
        if self.values[i] != nv:
            self.values[i] = nv
            self.changed.append(i)

    def get(self, i: Int) -> Int:
        return self.values[i]

    def drain(mut self) -> List[Int]:
        var out = self.changed^
        self.changed = List[Int]()
        return out^

    def to_bytes(self) -> List[UInt8]:
        var b = List[UInt8]()
        _put(b, len(self.names))
        for i in range(len(self.names)):
            var nb = self.names[i].as_bytes()
            _put(b, len(nb))
            for c in nb:
                b.append(c)
            _put(b, self.kinds[i])
            _put(b, self.values[i])
        return b^

    def load(mut self, b: List[UInt8]) raises:
        """Restore values by name into this (declared) set. Unknown names are
        added; a known name with another kind raises."""
        var at = 0
        var n = _get(b, at)
        if n < 0 or n > 1 << 24:
            raise Error("Flags.load: corrupt count")
        for _ in range(n):
            var ln = _get(b, at)
            if ln < 0 or at + ln > len(b):
                raise Error("Flags.load: truncated name")
            var chars = List[UInt8]()
            for k in range(ln):
                chars.append(b[at + k])
            at += ln
            var name = String(unsafe_from_utf8=chars)
            var kind = _get(b, at)
            var v = _get(b, at)
            var i = self.declare(name, kind)
            self.values[i] = v


def _put(mut b: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        b.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _get(b: List[UInt8], mut at: Int) raises -> Int:
    if at + 8 > len(b):
        raise Error("flow: truncated state")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(b[at + k]) << UInt64(8 * k)
    at += 8
    return Int(u)
