"""A dynamic character body: a floating capsule in the solver (ROADMAP 17.66).

`CharacterController` (17.1) and `Mover` (17.67) move a kinematic capsule by
sweeps; nothing pushes it except code that calls `add_velocity`.
`DynamicCharacter` is the other backend: a capsule body inside
`ContactScene6` (rotation locked, friction 0), held at `ride` metres above
the ground by a spring-damper along a downward ray, and steered by a
horizontal force toward the wished velocity, capped at `max_accel`
(`air_control` of it in the air). Because it is a body, explosions, vehicles
and heavier bodies push it with the right mass ratio, and it pushes back:
the ground spring's reaction goes to the body under it.

The spring includes gravity compensation (m |g|), so the rest height is
exactly `ride`, not `ride` minus a sag; stiffness from `spring_hz`
(k = m (2 pi f)^2), damping from `damping_ratio`.

On flat ground with the same wish and accel it matches `Mover` with
`MODEL_ACCEL` in steady speed and stopping distance (`test_phys_character`);
under an external impulse the two differ, which is the point.
"""

from std.math import pi, sqrt
from geometry.vec import Real, Vec3, length
from collision.world_query import QueryFilter
from physics.body_set import BodyId
from physics.rigid6 import Body6, Inertia3
from physics.solver6 import ContactScene6


struct DynamicCharacter(Copyable, Movable):
    var id: BodyId
    var mass: Real
    var radius: Real
    var half_height: Real
    var ride: Real  # capsule centre above the ground
    var probe: Real  # how far below `ride` the ground is still felt
    var spring_hz: Real
    var damping_ratio: Real
    var max_accel: Real
    var air_control: Real
    var on_ground: Bool
    var ground_body: Int
    var prev_y: Real  # centre height at the last update (NaN: none yet)

    def __init__(out self, id: BodyId, mass: Real, radius: Real, half_height: Real, ride: Real):
        self.id = id
        self.mass = mass
        self.radius = radius
        self.half_height = half_height
        self.ride = ride
        self.probe = 0.3
        self.spring_hz = 4
        self.damping_ratio = 1
        self.max_accel = 20
        self.air_control = 0.3
        self.on_ground = False
        self.ground_body = -1
        self.prev_y = Real(0) / Real(0)

    @staticmethod
    def spawn[B: Body6](mut sc: ContactScene6[B], var body: B, mass: Real, radius: Real, half_height: Real, ride: Real) raises -> DynamicCharacter:
        """Add the capsule (axis along y) and configure it: rotation locked,
        friction 0, sleep off. `ride` must keep the capsule's bottom above the
        ground (ride > half_height + radius)."""
        if ride <= half_height + radius:
            raise Error("DynamicCharacter: ride must exceed half_height + radius")
        var id = sc.add_capsule(body^, radius, half_height, False)
        sc.set_axis_locks(id, False, False, False, True, True, True)
        sc.set_friction(id.index(), 0)
        sc.set_sleep_thresholds(id, 0, 0)
        return DynamicCharacter(id, mass, radius, half_height, ride)

    def update[B: Body6](mut self, mut sc: ContactScene6[B], wish: Vec3, dt: Real, gravity: Vec3) raises:
        """Accumulate this tick's forces (call before `sc.step`)."""
        var p = sc.pose(self.id).pos
        var v = sc.velocity(self.id)
        var f = QueryFilter.all()
        f.ignore = self.id.index()
        var h = sc.ray_cast(p, Vec3(0, -1, 0, 0), self.ride + self.probe, f)
        self.on_ground = h.hit
        self.ground_body = h.body if h.hit else -1
        var force = Vec3(0, 0, 0, 0)
        if h.hit:
            var w = 2 * Real(pi) * self.spring_hz
            var k = self.mass * w * w
            var c = 2 * self.damping_ratio * self.mass * w
            var g = length(gravity)
            # Damp on the height change per tick, not on the body's
            # end-of-step velocity: the solver applies accumulated force once
            # at the start of the step and gravity every substep, so at rest
            # the end-of-step velocity reads -0.061 m/s (4 substeps, 1/60 s)
            # and damping it held the body 6.5 mm high (measured).
            var vy = (p[1] - self.prev_y) / dt if self.prev_y == self.prev_y else v[1]
            var vy_rel = vy - sc.bset.bodies[h.body].velocity_at(h.point)[1]
            var fy = k * (self.ride - h.t) - c * vy_rel + self.mass * g
            if fy < 0:
                fy = 0  # the ground only pushes
            force = force + Vec3(0, fy, 0, 0)
            if sc.bset.is_dynamic(h.body):
                sc.add_force_at(sc.bset.id_of(h.body), Vec3(0, -fy, 0, 0), h.point)
        self.prev_y = p[1]
        var dvx = wish[0] - v[0]
        var dvz = wish[2] - v[2]
        var a = self.max_accel * (Real(1) if h.hit else self.air_control)
        var need = sqrt(dvx * dvx + dvz * dvz) / dt
        var s = min(Real(1), a / need) if need > 0 else Real(0)
        force = force + Vec3(dvx / dt * s, 0, dvz / dt * s, 0) * self.mass
        sc.add_force(self.id, force)
