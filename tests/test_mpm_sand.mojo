# tier: component
"""MPM static obstacles and the experimental Drucker-Prager sand (ROADMAP
17.58, `MpmSolver.add_obstacle`, `MpmSolver.set_sand`, `step_ext`).

  1. Ordinary (obstacles): an elastic block on an obstacle floor (mu 0.6)
     given 2 m/s slides 0.346 m, v^2 / (2 mu g) = 0.340 (2 %); on a mu 0
     floor it keeps sliding. Sand poured onto a box obstacle: no particle
     ends deeper than half a cell inside it, some rest on top.
  2. Integration (sand, measured behaviour): a column (0.24 x 0.42 x 0.24 m)
     on the obstacle floor after 0.3 s keeps more height the larger the
     friction angle (30 < 60 < 85 degrees) and stands at 85.
  2b. A 0.24 m block released on the floor settles to a heap whose equal-volume
     cone (slope 3 V / (pi R^3)) is 23 degrees steep at 20 degrees of friction
     and 32.6 at 40 (the heaps stay below the friction angle at large angles
     because the collapse overshoots). `experiments/exp_sand_repose.mojo` has
     the sweep on a larger block (20.4 / 25.0 / 28.8 / 31.8 degrees at 20 /
     30 / 40 / 50), and a cone of slope 41 degrees still stands at 35 degrees
     of friction (peak 0.97 after 1 s; Drucker-Prager matched to triaxial
     compression is stronger than Mohr-Coulomb in plane strain). Before the
     volumetric stress was applied in the right frame and the obstacle nodes
     on the floor surface were projected, the same columns spread to a film
     (0.6 degrees at 30 degrees of friction).
  3. Extreme: friction angles 0 and 90 and a negative obstacle mu raise; the
     runs stay finite and inside the grid.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.mat import Mat3
from geometry.sdf3 import Sdf3
from std.math import atan2, sqrt
from physics.mpm import MpmSolver

comptime DX: Real = 0.05
comptime N = 32
comptime G = Vec3(0, -9.8, 0, 0)
comptime DT: Real = 1.0 / 2000.0
comptime FLOOR: Real = 0.2  # top of the floor obstacle


def _floor(mut m: MpmSolver, mu: Real) raises:
    m.add_obstacle(Sdf3.box(Vec3(0.8, 0.0, 0.8, 0), Vec3(1.0, FLOOR, 1.0, 0)), mu)


def _block(mut m: MpmSolver, ox: Real, oy: Real, oz: Real, nx: Int, ny: Int, nz: Int):
    var sp = Real(0.03)
    var vol = sp * sp * sp
    for i in range(nx):
        for j in range(ny):
            for k in range(nz):
                m.add(Vec3(ox + Real(i) * sp, oy + Real(j) * sp, oz + Real(k) * sp, 0), vol * 1600.0, vol)


def _mean_x(m: MpmSolver) -> Real:
    var acc = Real(0)
    for ref q in m.p:
        acc += q.x[0]
    return acc / Real(m.count())


def _top(m: MpmSolver) -> Real:
    var t = Real(-1e30)
    for ref q in m.p:
        t = max(t, q.x[1])
    return t - FLOOR


def _ok(m: MpmSolver) -> Bool:
    var top = Real(N) * DX
    for ref q in m.p:
        for a in range(3):
            if not (q.x[a] > -1e-3 and q.x[a] < top + 1e-3):
                return False
    return True


def _slide(mu: Real) raises -> Real:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    _floor(m, mu)
    _block(m, 0.3, FLOOR + 0.015, 0.68, 6, 4, 6)
    for _ in range(200):
        m.step_ext(DT, G)
    var x0 = _mean_x(m)
    for pi in range(m.count()):
        m.p[pi].v = Vec3(2, m.p[pi].v[1], 0, 0)
    for _ in range(1200):
        m.step_ext(DT, G)
    return _mean_x(m) - x0


def _column(phi: Real) raises -> MpmSolver:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    _floor(m, 0.6)
    if phi > 0:
        m.set_sand(phi)
    _block(m, 0.68, FLOOR + 0.015, 0.68, 8, 14, 8)
    for _ in range(600):
        m.step_ext(DT, G)
    return m^


def _det(f: Mat3) -> Real:
    return (
        f.get(0, 0) * (f.get(1, 1) * f.get(2, 2) - f.get(1, 2) * f.get(2, 1))
        - f.get(0, 1) * (f.get(1, 0) * f.get(2, 2) - f.get(1, 2) * f.get(2, 0))
        + f.get(0, 2) * (f.get(1, 0) * f.get(2, 1) - f.get(1, 1) * f.get(2, 0))
    )


def _heap_cone_deg(phi: Real) raises -> Real:
    var m = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    _floor(m, 1.0)
    m.set_sand(phi)
    _block(m, 0.8 - 0.12, FLOOR + 0.015, 0.8 - 0.12, 8, 8, 8)
    for _ in range(3000):
        m.step_ext(DT, G)
    var cx = Real(0)
    var cz = Real(0)
    var v = Real(0)
    for ref q in m.p:
        cx += q.x[0]
        cz += q.x[2]
        v += q.vol * _det(q.f)
    cx /= Real(m.count())
    cz /= Real(m.count())
    var rmax = Real(0)
    for ref q in m.p:
        rmax = max(rmax, sqrt((q.x[0] - cx) * (q.x[0] - cx) + (q.x[2] - cz) * (q.x[2] - cz)))
    return atan2(3 * v, 3.141592653589793 * rmax * rmax * rmax) * 57.29577951308232


def main() raises:
    var s = Suite("mpm_sand")
    var d6 = _slide(0.6)
    var d0 = _slide(0)
    print("  block at 2 m/s on the obstacle floor: slides", d6, "m with mu 0.6 (v^2/2 mu g = 0.340);", d0, "m with mu 0")
    s.check(abs(d6 - 0.340) < 0.02 * 0.340 + 0.005 and d0 > 2 * d6, "obstacle friction stops the block where Coulomb says")

    var o = MpmSolver(Vec3(0, 0, 0, 0), DX, N, 2.0e5, 0.3)
    var box = Sdf3.box(Vec3(0.8, 0.4, 0.8, 0), Vec3(0.2, 0.25, 0.2, 0))
    o.add_obstacle(box, 0.5)
    o.set_sand(35)
    _block(o, 0.71, 0.75, 0.71, 6, 8, 6)
    for _ in range(2400):
        o.step_ext(DT, G)
    var deep = 0
    var on_top = 0
    for ref q in o.p:
        if box.distance(q.x) < -0.5 * DX:
            deep += 1
        if q.x[1] > 0.65 and abs(q.x[0] - 0.8) < 0.2 and abs(q.x[2] - 0.8) < 0.2:
            on_top += 1
    print("  sand poured on a box: particles deeper than half a cell inside", deep, " resting on its top", on_top, "of", o.count())
    s.check(deep == 0 and on_top > 0, "the obstacle holds the sand: none inside, some on top")

    var h0 = Real(14) * 0.03
    var tops = List[Real]()
    var spreads = List[Real]()
    var fine = True
    for phi in [Real(0), Real(30), Real(60), Real(85)]:
        var m = _column(phi)
        tops.append(_top(m))
        var lo = Real(1e30)
        var hi = Real(-1e30)
        for ref q in m.p:
            lo = min(lo, q.x[0])
            hi = max(hi, q.x[0])
        spreads.append(hi - lo)
        fine = fine and _ok(m)
    print("  column", h0, "m after 0.3 s, top / spread: elastic", tops[0], spreads[0], "; sand 30 deg", tops[1], spreads[1], "; 60 deg", tops[2], spreads[2], "; 85 deg", tops[3], spreads[3])
    s.check(tops[1] < tops[2] and tops[2] < tops[3] and tops[3] > 0.75 * h0, "taller with the friction angle; 85 degrees stands")
    s.check(fine, "every run stays finite and inside the grid")

    var c20 = _heap_cone_deg(20)
    var c40 = _heap_cone_deg(40)
    print("  heap from a 0.24 m block, equal-volume cone angle: friction 20 ->", c20, "; 40 ->", c40)
    s.check(abs(c20 - 20) < 4, "a heap at 20 degrees of friction is a cone near 20 degrees")
    s.check(c40 > c20 + 4 and c40 < 42, "a larger friction angle gives a steeper heap, below the friction angle")

    var raised = 0
    for phi in [Real(0), Real(90)]:
        try:
            var m = MpmSolver(Vec3(0, 0, 0, 0), DX, 8, 1e4, 0.3)
            m.set_sand(phi)
        except:
            raised += 1
    try:
        var m = MpmSolver(Vec3(0, 0, 0, 0), DX, 8, 1e4, 0.3)
        m.add_obstacle(box, -1)
    except:
        raised += 1
    s.check(raised == 3, "friction 0 / 90 degrees and negative obstacle mu raise")
    s.finish()
