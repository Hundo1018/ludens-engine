"""Live tuning: typed, range-checked settings applied at a tick boundary (ludens-shell #14, live tuning).

Same rules as the engine's Python `ludens.cvar`: a variable has a name, an integer or float type, a default and optional
bounds. `set` parses text (so a console line and `ludens cmd` use it), refuses a value that is not of the type, not
finite or out of range, and queues the change; it never touches the world. `apply` is called at the start of a tick
(between ticks) and applies the queued changes in the order they were set, so a run that sets `physics.iterations 4`
at tick 60 is bit-identical to one that calls `world.set_solver(4, ...)` before tick 60.

Built-in bindings (the table is fixed, nothing else is reachable): `physics.iterations`, `physics.substeps` (ints >= 1,
applied with `EmbedWorld.set_solver`) and `physics.gravity_y` (float, applied with `set_gravity`, x and z kept)."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3

comptime CV_INT = 0
comptime CV_FLOAT = 1


struct CVar(Copyable, Movable):
    var name: String
    var kind: Int
    var value: Float64
    var lo: Float64
    var hi: Float64

    def __init__(out self, name: String, kind: Int, default: Float64, lo: Float64, hi: Float64):
        self.name = name
        self.kind = kind
        self.value = default
        self.lo = lo
        self.hi = hi


struct CVarSet(Movable):
    var vars: List[CVar]
    var queue_names: List[String]
    var queue_values: List[Float64]

    def __init__(out self):
        self.vars = List[CVar]()
        self.queue_names = List[String]()
        self.queue_values = List[Float64]()
        self.vars.append(CVar("physics.iterations", CV_INT, 8, 1, 64))
        self.vars.append(CVar("physics.substeps", CV_INT, 1, 1, 16))
        self.vars.append(CVar("physics.gravity_y", CV_FLOAT, -9.81, -1000, 1000))

    def find(self, name: String) -> Int:
        for i in range(len(self.vars)):
            if self.vars[i].name == name:
                return i
        return -1

    def get(self, name: String) raises -> Float64:
        var i = self.find(name)
        if i < 0:
            raise Error("cvar: unknown variable `" + name + "`")
        return self.vars[i].value

    def set(mut self, name: String, text: String) raises:
        var i = self.find(name)
        if i < 0:
            raise Error("cvar: unknown variable `" + name + "`")
        var v: Float64
        try:
            v = Float64(text)
        except:
            raise Error("cvar " + name + ": `" + text + "` is not a number")
        if v != v or v > 1.0e300 or v < -1.0e300:
            raise Error("cvar " + name + ": `" + text + "` is not finite")
        if self.vars[i].kind == CV_INT and Float64(Int(v)) != v:
            raise Error("cvar " + name + ": `" + text + "` is not a whole number")
        if v < self.vars[i].lo:
            raise Error("cvar " + name + ": " + text + " is below the minimum " + String(self.vars[i].lo))
        if v > self.vars[i].hi:
            raise Error("cvar " + name + ": " + text + " is above the maximum " + String(self.vars[i].hi))
        self.queue_names.append(name)
        self.queue_values.append(v)

    def pending(self) -> Int:
        return len(self.queue_names)

    def apply(mut self, mut world: EmbedWorld, mut iters: Int, mut substeps: Int) raises:
        """Apply queued changes in order. `iters` / `substeps` are the caller's current solver settings (EmbedWorld has
        no getter), updated here so successive calls compose."""
        var gy_changed = False
        var gy = Float64(0)
        for k in range(len(self.queue_names)):
            var i = self.find(self.queue_names[k])
            self.vars[i].value = self.queue_values[k]
            if self.queue_names[k] == "physics.iterations":
                iters = Int(self.queue_values[k])
            elif self.queue_names[k] == "physics.substeps":
                substeps = Int(self.queue_values[k])
            else:
                gy_changed = True
                gy = self.queue_values[k]
        if len(self.queue_names) > 0:
            world.set_solver(iters, substeps)
            if gy_changed:
                world.set_gravity(Vec3(0, Real(gy), 0, 0))
        self.queue_names = List[String]()
        self.queue_values = List[Float64]()
