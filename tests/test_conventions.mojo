# tier: integration
"""Coordinate conventions the embedding contract states (ROADMAP 17.75,
docs/design/17.75-embedding-contract.md), pinned so a change to any of them
fails here first.

  1. Right-handed: cross(+X, +Y) = +Z.
  2. Rotation sense: a positive angle about +Y takes +X to -Z (right-hand
     rule), and about +Z takes +X to +Y.
  3. Quat layout: fields x, y, z, w with w the scalar part (identity w = 1);
     from_axis_angle(+Y, 90 deg) = (0, sin 45, 0, cos 45).
  4. Units: SI (the solver's absolute tolerances are metres and m/s by
     default; `UnitScale` rescales them -- test_unit_scale).
"""

from std.math import pi, sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, cross
from geometry.quat import Quat
from physics.solver_config import SolverConfig, UnitScale


def main() raises:
    var s = Suite("conventions")
    var z = cross(Vec3(1, 0, 0, 0), Vec3(0, 1, 0, 0))
    s.check(z[0] == 0 and z[1] == 0 and z[2] == 1, "right-handed: X x Y = +Z")

    var qy = Quat.from_axis_angle(Vec3(0, 1, 0, 0), pi / 2)
    var r = qy.rotate(Vec3(1, 0, 0, 0))
    s.almost(Float64(r[2]), -1.0, "+90 deg about +Y takes +X to -Z", 1e-6)
    var qz = Quat.from_axis_angle(Vec3(0, 0, 1, 0), pi / 2)
    var r2 = qz.rotate(Vec3(1, 0, 0, 0))
    s.almost(Float64(r2[1]), 1.0, "+90 deg about +Z takes +X to +Y", 1e-6)

    var id = Quat.identity()
    s.check(id.w == 1 and id.x == 0 and id.y == 0 and id.z == 0, "Quat fields x, y, z, w; identity has w = 1")
    s.almost(Float64(qy.y), Float64(sqrt(0.5)), "from_axis_angle(+Y, 90 deg).y = sin 45", 1e-6)
    s.almost(Float64(qy.w), Float64(sqrt(0.5)), "from_axis_angle(+Y, 90 deg).w = cos 45", 1e-6)

    var c = SolverConfig()
    var cm = UnitScale(100).apply(c)
    s.almost(Float64(cm.margin_base), Float64(c.margin_base) * 100, "UnitScale(100) (centimetres) scales the margin", 1e-6)
    s.check(cm.ang_sleep_tol == c.ang_sleep_tol and cm.sleep_time == c.sleep_time, "angular (rad/s) and time (s) knobs are unit-free")
    s.finish()
