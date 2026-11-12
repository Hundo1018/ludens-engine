"""Event sheets: deterministic, data-driven game logic (ludens-engine #24, first slice).

A sheet is text, one block per event:

    event 1 once
      when tick_mod 30            every 30th tick
      when var score >= 3         compare a variable (== != < <= > >=)
      when exists 4               body handle 4 is alive
      when below 4 -2.0           the y of body 4 is below -2.0
      when on go                  the signal `go` was emitted earlier in this tick
      when key fire               the host reports input `fire` held (`Sheet.set_input`)
      when pressed fire           `fire` went down since the previous tick
      when touching 4 7           bodies 4 and 7 were in contact after the latest physics tick (either order)
      do add score 1              score += 1
      do set lives 3              lives = 3
      do velocity 4 0 5 0         set the linear velocity of body 4
      do impulse 4 0 5 0          apply a velocity change to body 4
      do remove 4                 remove body 4
      do emit go                  raise the signal `go`
      do spawn_box b 0 5 0 .4 .4 .4 1   add a box, its handle goes into variable b
      do spawn_sphere b 0 5 0 .3 1      add a sphere (at most 1000 per sheet, the rest counted in `spawn_cut`)
      do sound 3                  ask the host to play its sound cue 3 (`Sheet.take_sounds`)
      do scene level2             ask the host to change to the scene `level2` (`Sheet.take_scene`)
    event 2 parent 1              runs only in a tick where event 1's conditions held

An event runs when all its `when` lines hold (none = always). The tables of conditions and actions are fixed: each
action is one call on `EmbedWorld` or on the sheet's own variables, and a sheet has no other way out (no host calls, no
files, no network), which is what lets it ship in a game that must not download code. `sound` is no exception: it only
appends a number to a list the host reads; which sound that number means, and whether one plays, is the host's.
`scene` likewise only records a name (letters, digits, `_` and `-`: it cannot be a path); loading is the host's.

Bounded: every event runs at most once per tick, signals are seen in the same tick by events later in the sheet, and an
`emit` for an event that already ran this tick is dropped and counted in `cut` (a chain A -> B -> A stops at once and
is reported, it cannot loop). The worst case per tick is one evaluation of every event. Variables are integers (no
float drift); positions and velocities are the world's.

An action on a body that is gone does nothing (a sheet may outlive the objects it names).

Errors in a sheet name the event or the line: unknown condition or action, wrong argument count, a number that is not
one, a parent that does not exist or comes later, a duplicate event id."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3

comptime C_TICK_MOD = 0
comptime C_VAR = 1
comptime C_EXISTS = 2
comptime C_BELOW = 3
comptime C_ON = 4
comptime C_KEY = 5  # n = 0: held, 1: went down this tick
comptime C_TOUCHING = 6  # handle = body a, n = body b

comptime A_ADD = 0
comptime A_SET = 1
comptime A_VELOCITY = 2
comptime A_IMPULSE = 3
comptime A_REMOVE = 4
comptime A_EMIT = 5
comptime A_SPAWN_BOX = 6
comptime A_SPAWN_SPHERE = 7
comptime A_SOUND = 8  # n = the host's cue number
comptime A_SCENE = 9  # name = the scene asked for

comptime MAX_SPAWNS = 1000  # per sheet; further spawns are dropped and counted in `spawn_cut`
comptime MAX_PENDING_SOUNDS = 64  # cues not yet taken by the host; further ones are dropped and counted in `sound_cut`

comptime OP_EQ = 0
comptime OP_NE = 1
comptime OP_LT = 2
comptime OP_LE = 3
comptime OP_GT = 4
comptime OP_GE = 5


@fieldwise_init
struct Cond(Copyable, Movable):
    var kind: Int
    var name: String  # variable or signal name
    var handle: Int64
    var n: Int  # tick_mod divisor, or the integer to compare with
    var op: Int
    var y: Real


@fieldwise_init
struct Act(Copyable, Movable):
    var kind: Int
    var name: String
    var handle: Int64
    var n: Int
    var v: Vec3
    var h: Vec3  # spawn_box half extents (x), spawn_sphere radius (x)
    var m: Real  # spawn mass


@fieldwise_init
struct Event(Copyable, Movable):
    var id: Int
    var parent: Int  # index into Sheet.events, -1 = none
    var once: Bool
    var conds: List[Cond]
    var acts: List[Act]


def _num(t: String, what: String) raises -> Real:
    try:
        return Real(Float64(t))
    except:
        raise Error(what + " must be a number, got `" + t + "`")


def _int(t: String, what: String) raises -> Int:
    try:
        return Int(t)
    except:
        raise Error(what + " must be a whole number, got `" + t + "`")


def _words(line: String) -> List[String]:
    var out = List[String]()
    for w in line.split(" "):
        var s = String(w.strip())
        if s.byte_length() > 0:
            out.append(s)
    return out^


struct Sheet(Movable):
    var events: List[Event]
    var var_names: List[String]
    var var_values: List[Int]
    var ran: List[Bool]  # per event, this tick
    var held: List[Bool]  # per event, conditions held this tick
    var fired_once: List[Bool]
    var signals: List[String]  # emitted this tick
    var cut: Int  # emits dropped because their target had already run this tick
    var tick: Int
    var input_names: List[String]
    var input_down: List[Bool]
    var input_prev: List[Bool]  # state at the previous step, for `pressed`
    var spawned: Int
    var spawn_cut: Int
    var sounds: List[Int]  # cues asked for and not yet taken, oldest first
    var sound_cut: Int
    var next_scene: String  # the scene asked for and not yet taken; the latest request wins

    def __init__(out self):
        self.events = List[Event]()
        self.var_names = List[String]()
        self.var_values = List[Int]()
        self.ran = List[Bool]()
        self.held = List[Bool]()
        self.fired_once = List[Bool]()
        self.signals = List[String]()
        self.cut = 0
        self.tick = 0
        self.input_names = List[String]()
        self.input_down = List[Bool]()
        self.input_prev = List[Bool]()
        self.spawned = 0
        self.spawn_cut = 0
        self.sounds = List[Int]()
        self.sound_cut = 0
        self.next_scene = String()

    @staticmethod
    def parse(text: String) raises -> Sheet:
        var s = Sheet()
        var cur = -1
        var lines = text.split("\n")
        for ln in range(len(lines)):
            var raw = String(lines[ln])
            var hash_at = raw.find("#")
            var w: List[String]
            if hash_at >= 0:
                var head = String(raw[byte=0:hash_at])
                w = _words(head)
            else:
                w = _words(raw)
            if len(w) == 0:
                continue
            var at = "line " + String(ln + 1) + ": "
            try:
                if w[0] == "event":
                    if len(w) < 2:
                        raise Error("`event` needs an id")
                    var id = _int(w[1], "event id")
                    for e in s.events:
                        if e.id == id:
                            raise Error("event " + String(id) + " is defined twice")
                    var parent = -1
                    var once = False
                    var k = 2
                    while k < len(w):
                        if w[k] == "once":
                            once = True
                            k += 1
                        elif w[k] == "parent" and k + 1 < len(w):
                            var pid = _int(w[k + 1], "parent id")
                            for pi in range(len(s.events)):
                                if s.events[pi].id == pid:
                                    parent = pi
                            if parent < 0:
                                raise Error("parent " + String(pid) + " does not exist (a parent must be defined before its child)")
                            k += 2
                        else:
                            raise Error("unexpected `" + w[k] + "` after the event id")
                    s.events.append(Event(id, parent, once, List[Cond](), List[Act]()))
                    cur = len(s.events) - 1
                elif w[0] == "when" or w[0] == "do":
                    if cur < 0:
                        raise Error("`" + w[0] + "` before any `event`")
                    if len(w) < 2:
                        raise Error("`" + w[0] + "` needs a name")
                    if w[0] == "when":
                        s.events[cur].conds.append(Sheet._cond(w))
                    else:
                        s.events[cur].acts.append(Sheet._act(w))
                else:
                    raise Error("unknown line start `" + w[0] + "` (event, when, do)")
            except e:
                var who = ""
                if cur >= 0 and w[0] != "event":
                    who = "event " + String(s.events[cur].id) + ", "
                raise Error(at + who + String(e))
        for _ in range(len(s.events)):
            s.ran.append(False)
            s.held.append(False)
            s.fired_once.append(False)
        s._resolve()
        return s^

    @staticmethod
    def _cond(w: List[String]) raises -> Cond:
        var k = w[1]
        var none = Vec3(0, 0, 0, 0)
        _ = none
        if k == "tick_mod":
            if len(w) != 3:
                raise Error("tick_mod needs one number")
            var n = _int(w[2], "divisor")
            if n < 1:
                raise Error("tick_mod divisor must be >= 1")
            return Cond(C_TICK_MOD, String(), 0, n, 0, 0)
        if k == "var":
            if len(w) != 5:
                raise Error("var needs <name> <op> <number>")
            var op = -1
            if w[3] == "==":
                op = OP_EQ
            elif w[3] == "!=":
                op = OP_NE
            elif w[3] == "<":
                op = OP_LT
            elif w[3] == "<=":
                op = OP_LE
            elif w[3] == ">":
                op = OP_GT
            elif w[3] == ">=":
                op = OP_GE
            else:
                raise Error("unknown comparison `" + w[3] + "`")
            return Cond(C_VAR, w[2], 0, _int(w[4], "value"), op, 0)
        if k == "exists":
            if len(w) != 3:
                raise Error("exists needs a body handle")
            return Cond(C_EXISTS, String(), Int64(_int(w[2], "handle")), 0, 0, 0)
        if k == "below":
            if len(w) != 4:
                raise Error("below needs <handle> <y>")
            return Cond(C_BELOW, String(), Int64(_int(w[2], "handle")), 0, 0, _num(w[3], "y"))
        if k == "on":
            if len(w) != 3:
                raise Error("on needs a signal name")
            return Cond(C_ON, w[2], 0, 0, 0, 0)
        if k == "key" or k == "pressed":
            if len(w) != 3:
                raise Error(k + " needs an input name")
            return Cond(C_KEY, w[2], 0, 0 if k == "key" else 1, 0, 0)
        if k == "touching":
            if len(w) != 4:
                raise Error("touching needs two body handles")
            var a = _int(w[2], "handle")
            var b = _int(w[3], "handle")
            if a == b:
                raise Error("touching needs two different bodies")
            return Cond(C_TOUCHING, String(), Int64(a), b, 0, 0)
        raise Error("unknown condition `" + k + "` (tick_mod, var, exists, below, on, key, pressed, touching)")

    @staticmethod
    def _act(w: List[String]) raises -> Act:
        var k = w[1]
        var zero = Vec3(0, 0, 0, 0)
        if k == "add" or k == "set":
            if len(w) != 4:
                raise Error(k + " needs <name> <number>")
            return Act(A_ADD if k == "add" else A_SET, w[2], 0, _int(w[3], "value"), zero, zero, 0)
        if k == "velocity" or k == "impulse":
            if len(w) != 6:
                raise Error(k + " needs <handle> <x> <y> <z>")
            return Act(A_VELOCITY if k == "velocity" else A_IMPULSE, String(), Int64(_int(w[2], "handle")), 0, Vec3(_num(w[3], "x"), _num(w[4], "y"), _num(w[5], "z"), 0), zero, 0)
        if k == "remove":
            if len(w) != 3:
                raise Error("remove needs a body handle")
            return Act(A_REMOVE, String(), Int64(_int(w[2], "handle")), 0, zero, zero, 0)
        if k == "emit":
            if len(w) != 3:
                raise Error("emit needs a signal name")
            return Act(A_EMIT, w[2], 0, 0, zero, zero, 0)
        if k == "spawn_box":
            if len(w) != 10:
                raise Error("spawn_box needs <var> <x> <y> <z> <hx> <hy> <hz> <mass>")
            var hx = _num(w[6], "hx")
            var hy = _num(w[7], "hy")
            var hz = _num(w[8], "hz")
            var m = _num(w[9], "mass")
            if not (hx > 0 and hy > 0 and hz > 0) or not (m > 0):
                raise Error("spawn_box: half extents and mass must be > 0")
            return Act(A_SPAWN_BOX, w[2], 0, 0, Vec3(_num(w[3], "x"), _num(w[4], "y"), _num(w[5], "z"), 0), Vec3(hx, hy, hz, 0), m)
        if k == "spawn_sphere":
            if len(w) != 8:
                raise Error("spawn_sphere needs <var> <x> <y> <z> <radius> <mass>")
            var r = _num(w[6], "radius")
            var m = _num(w[7], "mass")
            if not (r > 0) or not (m > 0):
                raise Error("spawn_sphere: radius and mass must be > 0")
            return Act(A_SPAWN_SPHERE, w[2], 0, 0, Vec3(_num(w[3], "x"), _num(w[4], "y"), _num(w[5], "z"), 0), Vec3(r, 0, 0, 0), m)
        if k == "sound":
            if len(w) != 3:
                raise Error("sound needs a cue number")
            var cue = _int(w[2], "cue")
            if cue < 0:
                raise Error("sound: the cue number must be >= 0")
            return Act(A_SOUND, String(), 0, cue, zero, zero, 0)
        if k == "scene":
            if len(w) != 3:
                raise Error("scene needs a scene name")
            for b in w[2].as_bytes():
                var ok = (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b == 45
                if not ok:
                    raise Error("scene: the name `" + w[2] + "` may only have letters, digits, `_` and `-`")
            return Act(A_SCENE, w[2], 0, 0, zero, zero, 0)
        raise Error("unknown action `" + k + "` (add, set, velocity, impulse, remove, emit, spawn_box, spawn_sphere, sound, scene)")

    # ------------------------------------------------------------ running

    def take_sounds(mut self) -> List[Int]:
        """The cues `sound` actions asked for since the last call, in the order they ran; the list is then empty."""
        var out = self.sounds.copy()
        self.sounds.clear()
        return out^

    def _slot(mut self, name: String) -> Int:
        """The index of a variable, registered at 0 if new."""
        for i in range(len(self.var_names)):
            if self.var_names[i] == name:
                return i
        self.var_names.append(name)
        self.var_values.append(0)
        return len(self.var_names) - 1

    def _resolve(mut self):
        """After parsing: every variable a condition or an action names gets its index, kept in the otherwise unused
        `handle` field, so a tick does no name lookups (they made a sheet with one variable per event quadratic)."""
        for e in range(len(self.events)):
            for k in range(len(self.events[e].conds)):
                if self.events[e].conds[k].kind == C_VAR:
                    var name = self.events[e].conds[k].name.copy()
                    self.events[e].conds[k].handle = Int64(self._slot(name))
            for k in range(len(self.events[e].acts)):
                var kind = self.events[e].acts[k].kind
                if kind == A_ADD or kind == A_SET or kind == A_SPAWN_BOX or kind == A_SPAWN_SPHERE:
                    var name = self.events[e].acts[k].name.copy()
                    self.events[e].acts[k].handle = Int64(self._slot(name))

    def take_scene(mut self) -> String:
        """The scene a `scene` action asked for since the last call, or an empty string."""
        var out = self.next_scene.copy()
        self.next_scene = String()
        return out^

    def get(self, name: String) -> Int:
        for i in range(len(self.var_names)):
            if self.var_names[i] == name:
                return self.var_values[i]
        return 0

    def set_input(mut self, name: String, down: Bool):
        """The host reports an input (key, button, touch zone) before `step`. The sheet only reads this table."""
        for i in range(len(self.input_names)):
            if self.input_names[i] == name:
                self.input_down[i] = down
                return
        self.input_names.append(name)
        self.input_down.append(down)
        self.input_prev.append(False)

    def _input(self, name: String, edge: Bool) -> Bool:
        for i in range(len(self.input_names)):
            if self.input_names[i] == name:
                return self.input_down[i] and (not edge or not self.input_prev[i])
        return False

    def _signalled(self, name: String) -> Bool:
        for s in self.signals:
            if s == name:
                return True
        return False

    def _holds(self, c: Cond, world: EmbedWorld) raises -> Bool:
        if c.kind == C_TICK_MOD:
            return self.tick % c.n == 0
        if c.kind == C_VAR:
            var v = self.var_values[Int(c.handle)]
            if c.op == OP_EQ:
                return v == c.n
            if c.op == OP_NE:
                return v != c.n
            if c.op == OP_LT:
                return v < c.n
            if c.op == OP_LE:
                return v <= c.n
            if c.op == OP_GT:
                return v > c.n
            return v >= c.n
        if c.kind == C_EXISTS:
            return world.is_alive(c.handle)
        if c.kind == C_BELOW:
            return world.is_alive(c.handle) and world.state(c.handle).pos[1] < c.y
        if c.kind == C_KEY:
            return self._input(c.name, c.n == 1)
        if c.kind == C_TOUCHING:
            return world.touching(c.handle, Int64(c.n))
        return self._signalled(c.name)

    def _is_target_of(self, name: String, idx: Int) -> Bool:
        for c in self.events[idx].conds:
            if c.kind == C_ON and c.name == name:
                return True
        return False

    def step(mut self, mut world: EmbedWorld) raises:
        """One tick of the sheet: every event once, in order. Call once per physics tick, before or after the step."""
        self.signals = List[String]()
        for i in range(len(self.events)):
            self.ran[i] = False
            self.held[i] = False
        for i in range(len(self.events)):
            var ev = self.events[i].copy()
            if ev.once and self.fired_once[i]:
                continue
            if ev.parent >= 0 and not self.held[ev.parent]:
                continue
            var ok = True
            for c in ev.conds:
                if not self._holds(c, world):
                    ok = False
                    break
            if not ok:
                continue
            self.held[i] = True
            self.ran[i] = True
            self.fired_once[i] = True
            for a in ev.acts:
                if a.kind == A_ADD:
                    self.var_values[Int(a.handle)] += a.n
                elif a.kind == A_SET:
                    self.var_values[Int(a.handle)] = a.n
                elif a.kind == A_VELOCITY:
                    if world.is_alive(a.handle):
                        var st = world.state(a.handle)
                        world.set_velocity(a.handle, a.v, st.omega)
                elif a.kind == A_IMPULSE:
                    if world.is_alive(a.handle):
                        world.apply_impulse(a.handle, a.v)
                elif a.kind == A_REMOVE:
                    if world.is_alive(a.handle):
                        world.remove(a.handle)
                elif a.kind == A_SPAWN_BOX or a.kind == A_SPAWN_SPHERE:
                    if self.spawned >= MAX_SPAWNS:
                        self.spawn_cut += 1
                    else:
                        var h: Int64
                        if a.kind == A_SPAWN_BOX:
                            h = world.add_box(a.v, a.h, a.m, False)
                        else:
                            h = world.add_sphere(a.v, a.h[0], a.m, False)
                        self.spawned += 1
                        self.var_values[Int(a.handle)] = Int(h)
                elif a.kind == A_SOUND:
                    if len(self.sounds) >= MAX_PENDING_SOUNDS:
                        self.sound_cut += 1
                    else:
                        self.sounds.append(a.n)
                elif a.kind == A_SCENE:
                    self.next_scene = a.name.copy()
                else:
                    # a signal reaches events later in the sheet; for one that already ran this tick it is cut
                    for j in range(len(self.events)):
                        if self._is_target_of(a.name, j) and self.ran[j]:
                            self.cut += 1
                    self.signals.append(a.name)
        for i in range(len(self.input_down)):
            self.input_prev[i] = self.input_down[i]
        self.tick += 1
