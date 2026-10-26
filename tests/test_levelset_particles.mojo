# tier: integration
"""Particle level set volume correction (ROADMAP 17.60,
`physics.mac_levelset_particles`).

A 32 x 32 cell box, dx 1/32, dt 1/240 s, 240 steps, gravity 0. The velocity is
a single vortex psi = A sin^2(pi x) sin^2(pi y) (zero normal flow on the walls),
set on the faces before the first step and kept divergence-free by the
projection. A disk of radius 0.25 m sits off centre in it and is stirred for
1 s. Volume (cells with phi < 0, times dx^2) is compared at the end with and
without the particle correction; the particle correction must keep more of it.
"""

from harness.runner import Suite
from geometry.vec import Real
from std.math import sin, cos, sqrt
from physics.mac_levelset import LevelSetWater2
from physics.mac_levelset_particles import LevelSetParticles

comptime PI: Real = 3.141592653589793


def _vortex(mut ls: LevelSetWater2, amp: Real):
    var n = ls.n
    var dx = ls.dx
    var k = Real(2) * PI
    for j in range(n):
        for i in range(n + 1):
            var x = Real(i) * dx
            var y = (Real(j) + 0.5) * dx
            # u = dpsi/dy
            ls.u[j * (n + 1) + i] = amp * sin(PI * x) * sin(PI * x) * k * sin(PI * y) * cos(PI * y)
    for j in range(n + 1):
        for i in range(n):
            var x = (Real(i) + 0.5) * dx
            var y = Real(j) * dx
            # v = -dpsi/dx
            ls.v[j * n + i] = -amp * k * sin(PI * x) * cos(PI * x) * sin(PI * y) * sin(PI * y)


def _run(with_particles: Bool) raises -> Real:
    var n = 32
    var dx = Real(1) / Real(n)
    var dt = Real(1.0) / Real(240)
    var ls = LevelSetWater2(n, dx, 0.0)
    ls.set_box(0.35, 0.35, 0.65, 0.65)
    # disk: replace the box by a circle of radius 0.15 centred (0.5, 0.5)
    for j in range(n):
        for i in range(n):
            var x = (Real(i) + 0.5) * dx - 0.5
            var y = (Real(j) + 0.5) * dx - 0.5
            ls.phi[j * n + i] = sqrt(x * x + y * y) - 0.15
    _vortex(ls, 0.6)
    var parts = LevelSetParticles(dx)
    if with_particles:
        parts.seed(ls, 3.0)
    for _ in range(240):
        ls.step(dt)
        if with_particles:
            parts.advect(ls, dt)
            _ = parts.correct(ls)
    return ls.volume()


def main() raises:
    var s = Suite("levelset_particles")
    var v0 = PI * 0.15 * 0.15
    var plain = _run(False)
    var corr = _run(True)
    print("  volume: initial", v0, "plain", plain, "particles", corr)
    s.check(corr > plain, "particle correction keeps more volume than the plain level set")
    s.check(abs(corr - v0) / v0 < 0.10, "with particles the volume stays within 10 % of the initial disk")
    s.finish()
