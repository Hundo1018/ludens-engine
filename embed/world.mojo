"""The embedding world (ROADMAP 12.1): the value-semantics API that
`embed/capi.mojo` exports one-to-one as C functions.

A host sees a world as an opaque handle plus plain numbers: bodies are
`Int64` handles (`slot | generation << 32`, so a handle to a removed body
stays detectably stale after its slot is reused), poses and velocities are
`Float32` triples / `x, y, z, w` quaternions, contact events are five
`Int64`s. Everything that can fail on caller input raises here (one
validation at the boundary); the C layer turns the raise into a status code
plus `ld_world_last_error`.

Stepping is fixed-step: `ticks_due(frame_dt)` runs the same accumulator as
`scheduler.gameloop.FixedLoop` (at most `max_steps` ticks per frame, excess
debt dropped), and each tick is `pre systems -> physics_tick -> post
systems`. Systems are host callbacks; the loop that calls them lives in the
C layer (`capi.mojo`), because a callback re-enters the API through the
handle and must not run while a Mojo reference to the world is held.

`save` / `load` round-trip the whole simulation state (tick, accumulator,
scene via `physics.serialize.scene_to_bytes`) exactly; `hash` is FNV-1a over
that blob, so two hosts that agree on `hash` agree on every body bit.
"""

from std.math import isfinite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import Inertia3, Pose6, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.serialize import scene_to_bytes, scene_from_bytes
from collision.world_query import QueryFilter
from collision.contact_events import ContactEvent

comptime ABI_MAJOR = 0
comptime ABI_MINOR = 1

# Status codes (negative = error). Frozen for v0.x: values never change.
comptime LD_OK = 0
comptime LD_ERR_HANDLE = -1  # null / destroyed world or nav handle
comptime LD_ERR_ARG = -2  # invalid argument (NaN, non-positive size, ...)
comptime LD_ERR_STALE = -3  # body handle removed or never issued
comptime LD_ERR_BUFFER = -4  # output buffer too small (call reports the size needed)
comptime LD_ERR_FORMAT = -5  # save blob truncated or from another format
comptime LD_ERR_CALLBACK = -6  # a host system returned non-zero; the step stopped there
comptime LD_ERR_STATE = -7  # operation refused in the current state

comptime PHASE_PRE = 0  # before the physics tick
comptime PHASE_POST = 1  # after the physics tick (this tick's contact events visible)

# Contact event kinds (same values as collision.contact_events EV_*).
comptime EVENT_BEGAN = 0
comptime EVENT_STAY = 1
comptime EVENT_ENDED = 2

comptime _SAVE_MAGIC = 0x3057444C  # "LDW0" little-endian
comptime _FNV_OFFSET = UInt64(0xCBF29CE484222325)
comptime _FNV_PRIME = UInt64(0x100000001B3)


def pack_body(id: BodyId) -> Int64:
    return Int64(id.slot) | (Int64(id.gen) << 32)


def unpack_body(h: Int64) -> BodyId:
    return BodyId(Int(h & 0xFFFFFFFF), UInt32(h >> 32))


def fnv1a(data: List[UInt8]) -> UInt64:
    var h = _FNV_OFFSET
    for b in data:
        h = (h ^ UInt64(b)) * _FNV_PRIME
    return h


def _finite3(v: Vec3) -> Bool:
    return isfinite(v[0]) and isfinite(v[1]) and isfinite(v[2])


@fieldwise_init
struct BodyState(Copyable, ImplicitlyCopyable, Movable):
    var pos: Vec3
    var rot: Quat
    var vel: Vec3
    var omega: Vec3


@fieldwise_init
struct RayResult(Copyable, ImplicitlyCopyable, Movable):
    var body: Int64  # -1 = no hit
    var t: Real
    var point: Vec3
    var normal: Vec3


@fieldwise_init
struct TickEvent(Copyable, ImplicitlyCopyable, Movable):
    """One contact event as the host sees it: body handles, not slots."""

    var tick: Int64
    var a: Int64
    var b: Int64
    var kind: Int64
    var feat: Int64


struct EmbedWorld(Movable):
    var scene: ContactScene6[QuatBody6]
    var cfg: SolverConfig
    var gravity: Vec3
    var dt: Float64
    var acc: Float64
    var max_steps: Int
    var tick: Int
    var debt_dropped: Int  # frames whose excess time was dropped (FixedLoop's E22 rule)
    var frame_events: List[TickEvent]  # every event of the ticks run by the current / last frame
    var tick_events: List[TickEvent]  # events of the latest tick only
    var error: String

    def __init__(out self, dt: Float64, gravity: Vec3, max_steps: Int = 8) raises:
        if not (dt > 0) or not isfinite(dt):
            raise Error("world: dt must be finite and > 0")
        if not _finite3(gravity):
            raise Error("world: gravity must be finite")
        if max_steps < 1:
            raise Error("world: max_steps must be >= 1")
        self.scene = ContactScene6[QuatBody6]()
        self.scene.events_on = True
        self.cfg = SolverConfig()
        self.cfg.broadphase = True
        self.gravity = gravity
        self.dt = dt
        self.acc = 0
        self.max_steps = max_steps
        self.tick = 0
        self.debt_dropped = 0
        self.frame_events = List[TickEvent]()
        self.tick_events = List[TickEvent]()
        self.error = String()

    # ------------------------------------------------------------ settings

    def set_solver(mut self, iters: Int, substeps: Int) raises:
        if iters < 1 or substeps < 1:
            raise Error("set_solver: iterations and substeps must be >= 1")
        self.cfg.iters = iters
        self.cfg.substeps = substeps

    def set_gravity(mut self, g: Vec3) raises:
        if not _finite3(g):
            raise Error("set_gravity: gravity must be finite")
        self.gravity = g

    # -------------------------------------------------------------- bodies

    def _check_new(self, pos: Vec3, mass: Real, is_static: Bool) raises:
        if not _finite3(pos):
            raise Error("add body: position must be finite")
        if not is_static and (not (mass > 0) or not isfinite(mass)):
            raise Error("add body: dynamic body mass must be finite and > 0")

    def add_box(mut self, pos: Vec3, half: Vec3, mass: Real, is_static: Bool) raises -> Int64:
        self._check_new(pos, mass, is_static)
        if not _finite3(half) or not (half[0] > 0 and half[1] > 0 and half[2] > 0):
            raise Error("add_box: half extents must be finite and > 0")
        var m = mass if not is_static else Real(1)
        var id = self.scene.add(QuatBody6.at_rest(pos, Inertia3.box(m, half[0], half[1], half[2])), half, is_static)
        return pack_body(id)

    def add_sphere(mut self, pos: Vec3, r: Real, mass: Real, is_static: Bool) raises -> Int64:
        self._check_new(pos, mass, is_static)
        if not (r > 0) or not isfinite(r):
            raise Error("add_sphere: radius must be finite and > 0")
        var m = mass if not is_static else Real(1)
        var id = self.scene.add_sphere(QuatBody6.at_rest(pos, Inertia3.sphere(m, r)), r, is_static)
        return pack_body(id)

    def is_alive(self, h: Int64) -> Bool:
        if h < 0:
            return False
        var id = unpack_body(h)
        if id.slot >= len(self.scene.bset.bodies):
            return False
        return self.scene.bset.is_valid(id)

    def _id(self, h: Int64) raises -> BodyId:
        if not self.is_alive(h):
            raise Error("stale or unknown body handle")
        return unpack_body(h)

    def remove(mut self, h: Int64) raises:
        self.scene.remove_body(self._id(h))

    def set_velocity(mut self, h: Int64, v: Vec3, w: Vec3) raises:
        if not _finite3(v) or not _finite3(w):
            raise Error("set_velocity: velocities must be finite")
        var id = self._id(h)
        self.scene.set_velocity(id, v, w)
        self.scene.wake(id)

    def apply_impulse(mut self, h: Int64, j: Vec3) raises:
        """Linear impulse through the centre of mass (kg m/s); wakes the island."""
        if not _finite3(j):
            raise Error("apply_impulse: impulse must be finite")
        var id = self._id(h)
        var i = id.index()
        if not self.scene.bset.is_dynamic(i):
            raise Error("apply_impulse: body is not dynamic")
        self.scene.apply_impulse(id, j, self.scene.pose(id).pos)

    def teleport(mut self, h: Int64, pos: Vec3, rot: Quat) raises:
        if not _finite3(pos) or not (isfinite(rot.x) and isfinite(rot.y) and isfinite(rot.z) and isfinite(rot.w)):
            raise Error("teleport: pose must be finite")
        var n2 = rot.x * rot.x + rot.y * rot.y + rot.z * rot.z + rot.w * rot.w
        if n2 < 1e-12:
            raise Error("teleport: quaternion must be non-zero")
        var s = 1 / n2 ** 0.5
        self.scene.teleport(self._id(h), Pose6(pos, Quat(rot.x * s, rot.y * s, rot.z * s, rot.w * s)))

    def state(self, h: Int64) raises -> BodyState:
        var i = self._id(h).index()
        ref b = self.scene.bset.bodies[i]
        return BodyState(b.position(), b.rotation(), b.linear_velocity(), b.omega_world())

    def is_sleeping(self, h: Int64) raises -> Bool:
        return self.scene.is_sleeping(self._id(h))

    def bodies(self) -> List[Int64]:
        """Handles of every live body, in slot order."""
        var out = List[Int64]()
        for i in range(len(self.scene.bset.bodies)):
            if not self.scene.bset.is_removed(i):
                out.append(pack_body(self.scene.bset.id_of(i)))
        return out^

    # ------------------------------------------------------------- queries

    def raycast(self, origin: Vec3, dir: Vec3, max_t: Real) raises -> RayResult:
        if not _finite3(origin) or not _finite3(dir) or not (max_t >= 0):
            raise Error("raycast: origin, direction and max_t must be finite, max_t >= 0")
        var l2 = dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]
        if l2 < 1e-12:
            raise Error("raycast: direction must be non-zero")
        var hit = self.scene.ray_cast(origin, dir / l2 ** 0.5, max_t, QueryFilter.all())
        if not hit.hit:
            return RayResult(-1, 0, Vec3(0), Vec3(0))
        return RayResult(pack_body(self.scene.bset.id_of(hit.body)), hit.t, hit.point, hit.normal)

    # ------------------------------------------------------------ stepping

    def ticks_due(mut self, frame_dt: Float64) raises -> Int:
        """Accumulate `frame_dt` and return how many fixed ticks to run now;
        also starts a new frame's event list."""
        if not (frame_dt >= 0) or not isfinite(frame_dt):
            raise Error("step: frame_dt must be finite and >= 0")
        self.frame_events.clear()
        self.acc += frame_dt
        var n = 0
        while self.acc >= self.dt and n < self.max_steps:
            self.acc -= self.dt
            n += 1
        if self.acc >= self.dt:
            self.acc = 0
            self.debt_dropped += 1
        return n

    def physics_tick(mut self):
        """One fixed tick of the scene; collects its contact events."""
        self.scene.step(Real(self.dt), self.gravity, self.cfg)
        self.tick_events.clear()
        for e in self.scene.events:
            var ev = TickEvent(
                Int64(self.tick),
                pack_body(self.scene.bset.id_of(e.a)),
                pack_body(self.scene.bset.id_of(e.b)),
                Int64(e.kind),
                Int64(e.feat),
            )
            self.tick_events.append(ev)
            self.frame_events.append(ev)
        self.tick += 1

    # -------------------------------------------------------- save / load

    def save(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put(out, UInt64(_SAVE_MAGIC))
        _put(out, UInt64(self.tick))
        _put(out, UInt64(self.acc.to_bits()))
        var body = scene_to_bytes(self.scene)
        _put(out, UInt64(len(body)))
        out.extend(body^)
        return out^

    def load(mut self, data: List[UInt8]) raises:
        """Replace the simulation state with a `save` blob. Settings (dt,
        gravity, solver, systems) are the host's and stay as they are."""
        var pos = 0
        if _get(data, pos) != UInt64(_SAVE_MAGIC):
            raise Error("load: not a ludens world blob")
        var tick = Int(_get(data, pos))
        var acc_bits = _get(data, pos)
        var acc = Pointer(to=acc_bits).unsafe_bitcast[Float64]()[]
        var n = Int(_get(data, pos))
        if n < 0 or pos + n != len(data):
            raise Error("load: blob length mismatch")
        var body = List[UInt8](capacity=n)
        for i in range(n):
            body.append(data[pos + i])
        var sc = scene_from_bytes(body^)
        sc.events_on = True
        self.scene = sc^
        self.tick = tick
        self.acc = acc
        self.frame_events.clear()
        self.tick_events.clear()

    def hash(self) -> UInt64:
        return fnv1a(self.save())


def _put(mut out: List[UInt8], v: UInt64):
    for k in range(8):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _get(data: List[UInt8], mut pos: Int) raises -> UInt64:
    if pos + 8 > len(data):
        raise Error("load: blob truncated")
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return v
