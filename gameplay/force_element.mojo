"""Force elements: vehicles as compositions (ROADMAP 17.74).

`Vehicle.update` (17.4) is a fixed wheeled pipeline. A `ForceElement` is one
piece of a vehicle that turns the body's state into forces on it: a
thruster, a wing (`aircraft.Wing`), a hull's buoyancy
(`watercraft.HullBuoyancy`). A boat is hull + thruster + rudder wing; a
plane is wings + thruster. Each element reads the body from the scene and
accumulates forces with `add_force_at` for the next step; elements on one
body are independent, so their order does not matter.
"""

from geometry.vec import Real, Vec3
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6


trait ForceElement:
    def apply(self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        """Accumulate this element's force for the next step; returns the
        force (world frame) for inspection."""
        ...


@fieldwise_init
struct Thruster(ForceElement, Copyable, Movable):
    """Thrust along a body-fixed direction at a body-fixed point (propeller,
    jet, RCS nozzle). `throttle` in [0, 1] (clamped)."""

    var local_pos: Vec3
    var local_dir: Vec3  # unit
    var max_thrust: Real  # N
    var throttle: Real

    def apply(self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var pose = sc.pose(id)
        var th = min(max(self.throttle, Real(0)), Real(1))
        var f = pose.rot.rotate(self.local_dir) * (th * self.max_thrust)
        if th > 0:
            sc.add_force_at(id, f, pose.pos + pose.rot.rotate(self.local_pos))
        return f
