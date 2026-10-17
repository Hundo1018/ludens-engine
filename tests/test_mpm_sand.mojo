# tier: component
"""MPM static obstacles and the experimental Drucker-Prager sand (ROADMAP
17.58, `MpmSolver.add_obstacle`, `MpmSolver.set_sand`, `step_ext`).

  1. Ordinary (obstacles): an elastic block on an obstacle floor (mu 0.6)
     given 2 m/s slides 0.346 m, v^2 / (2 mu g) = 0.340 (2 %); on a mu 0
     floor it keeps sliding. Sand poured onto a box obstacle: no particle
     ends deeper than half a cell inside it, some rest on top.
  2. Integration (sand, measured behaviour, not a validated material): a
     column (0.24 x 0.42 x 0.24 m) on the obstacle floor after 0.3 s keeps
     more height the larger the friction angle (30 < 60 < 85 degrees) and
     stands at 85; at 30 and 60 degrees it keeps spreading instead of
     stopping at a pile (printed: the angle of repose is not reproduced --
     the return mapping is Klar et al.'s, in log strain, while the stress
     law here is fixed-corotated; a suspected cause, not verified).
  3. Extreme: friction angles 0 and 90 and a negative obstacle mu raise; the
     runs stay finite and inside the grid.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.sdf3 import Sdf3
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
