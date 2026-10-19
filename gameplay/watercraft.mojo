"""Exact hull buoyancy by convex cutting (ROADMAP 17.74).

`physics.fields.box_submerged_sampled` and `water.float_body` integrate
buoyancy by sampling points inside a box. A hull is a convex polytope; cutting
it by the water plane (`geometry.polytope.polytope_split`) gives the
submerged piece exactly, and its volume and centroid give the buoyant force
rho g V and where it acts. The water plane is horizontal at the surface
height under the hull's centre (`WaterSurface.height`, so a Gerstner sea
moves it). With `slope_step > 0` the cutting plane also takes the surface's
slope at the hull's centre (central differences over that step), so a hull
longer than a wave's slope scale sees the surface tilt; buoyancy stays vertical.

Linear and angular damping act in proportion to the submerged fraction.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3
from geometry.polytope import Polytope, polytope_split, convex_hull
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.water import WaterSurface
from .force_element import ForceElement


struct HullBuoyancy[W: WaterSurface & Copyable & Deinitable](ForceElement, Movable):
    var hull: Polytope  # local frame
    var volume: Real
    var water: Self.W
    var rho: Real
    var gravity: Real
    var lin_drag: Real  # N s / m per m^3 submerged
    var ang_drag: Real  # N m s per m^3 submerged
    var slope_step: Real  # > 0: tilt the cutting plane by the surface slope, sampled over this step

    def __init__(out self, local_points: List[Float64], var water: Self.W, rho: Real = 1000, gravity: Real = 9.8, lin_drag: Real = 200, ang_drag: Real = 200, slope_step: Real = 0) raises:
        self.hull = convex_hull(local_points)
        if self.hull.is_empty():
            raise Error("HullBuoyancy: the hull points enclose no volume")
        self.volume = Real(self.hull.volume())
        self.water = water^
        self.rho = rho
        self.gravity = gravity
        self.lin_drag = lin_drag
        self.ang_drag = ang_drag
        self.slope_step = slope_step

    def submerged(self, sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Tuple[Real, Vec3]:
        """(volume, centroid) of the hull below the water plane."""
        var pose = sc.pose(id)
        var w = self.hull.copy()
        for k in range(w.nv()):
            var p = pose.pos + pose.rot.rotate(Vec3(Real(w.v[3 * k]), Real(w.v[3 * k + 1]), Real(w.v[3 * k + 2]), 0))
            w.v[3 * k] = Float64(p[0])
            w.v[3 * k + 1] = Float64(p[1])
            w.v[3 * k + 2] = Float64(p[2])
        var level = self.water.height(pose.pos[0], pose.pos[2], t)
        # plane n . x = d through (centre x, level, centre z); n = (-sx, 1, -sz) / |.|
        var nx = Float64(0)
        var nz = Float64(0)
        var ny = Float64(1)
        if self.slope_step > 0:
            var h = self.slope_step
            var sx = (self.water.height(pose.pos[0] + h, pose.pos[2], t) - self.water.height(pose.pos[0] - h, pose.pos[2], t)) / (2 * h)
            var sz = (self.water.height(pose.pos[0], pose.pos[2] + h, t) - self.water.height(pose.pos[0], pose.pos[2] - h, t)) / (2 * h)
            var inv = 1.0 / sqrt(1.0 + Float64(sx * sx + sz * sz))
            nx = -Float64(sx) * inv
            nz = -Float64(sz) * inv
            ny = inv
        var d = nx * Float64(pose.pos[0]) + ny * Float64(level) + nz * Float64(pose.pos[2])
        var lo = Float64(1e30)
        var hi = Float64(-1e30)
        for k in range(w.nv()):
            var sk = nx * w.v[3 * k] + ny * w.v[3 * k + 1] + nz * w.v[3 * k + 2] - d
            lo = min(lo, sk)
            hi = max(hi, sk)
        if lo >= 0:
            return (Real(0), pose.pos)
        if hi <= 0:
            var c = w.centroid()
            return (self.volume, Vec3(Real(c[0]), Real(c[1]), Real(c[2]), 0))
        var sp = polytope_split(w, nx, ny, nz, d, -2, 1e-9)
        var below = sp^.into_back()
        if below.is_empty():
            return (Real(0), pose.pos)
        var c = below.centroid()
        return (Real(below.volume()), Vec3(Real(c[0]), Real(c[1]), Real(c[2]), 0))

    def apply(mut self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        var sub = self.submerged(sc, id, t)
        if sub[0] <= 0:
            return Vec3(0, 0, 0, 0)
        var f = Vec3(0, self.rho * self.gravity * sub[0], 0, 0)
        sc.add_force_at(id, f, sub[1])
        var frac = sub[0] / self.volume
        var v = sc.velocity(id)
        var om = sc.angular_velocity(id)
        sc.add_force(id, v * (-self.lin_drag * sub[0]))
        sc.add_torque(id, om * (-self.ang_drag * sub[0] * frac))
        return f
