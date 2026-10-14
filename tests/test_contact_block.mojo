# tier: integration
"""Block contact solver (ROADMAP 17.50, `SolverConfig.contact_solver`):
CONTACT_GS solves a manifold's normal impulses one point at a time,
CONTACT_BLOCK all of its points together.

  1. Parity: a sphere (one-point manifolds) falls and rolls bit for bit
     the same under both; a box at rest on the floor (four points) settles
     at the same height (1e-5 m).
  2. Integration: a 10-box stack with 1 iteration per substep; a 100 kg box
     on a 1 kg box (mass ratio 1:100); a box tipped onto one edge. The
     block solve solves each manifold's normals exactly, so a 4-point box
     under a uniform load gets four equal impulses (the sequential sweep
     spreads them over 20 % at 1 iteration) and the stack does not creep
     sideways (the sweep's point order tilts it by mm); both compress the
     stack alike. The heavy-on-light penetration is printed: the block
     solve does not change it (the soft contact sets it, not the sweep).
  3. Extreme: an unknown `contact_solver` is rejected by `validated`;
     adhesion falls back to the per-point sweep (same result as GS).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig, CONTACT_GS, CONTACT_BLOCK

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _cfg(kind: Int, iters: Int) -> SolverConfig:
    var c = SolverConfig()
    c.contact_solver = kind
    c.iters = iters
    return c


def _floor(mut sc: ContactScene6[QuatBody6]) raises:
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 50, 1, 50)), Vec3(50, 1, 50, 0), True)


def _box(mut sc: ContactScene6[QuatBody6], p: Vec3, m: Real) raises -> Int:
    var b = sc.add(QuatBody6.at_rest(p, Inertia3.box(m, 0.5, 0.5, 0.5)), Vec3(0.5, 0.5, 0.5, 0), False)
    sc.set_sleep_thresholds(b, 0, 0)
    return b.index()


def _stack(kind: Int, n: Int, iters: Int) raises -> Tuple[Real, Real]:
    """(top box drop from its stacked height, largest sideways drift) after 4 s."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var ids = List[Int]()
    for k in range(n):
        ids.append(_box(sc, Vec3(0, 0.5 + Real(k), 0, 0), 1))
    var cfg = _cfg(kind, iters)
    for _ in range(240):
        sc.step(DT, G, cfg)
    var top = sc.bset.bodies[ids[n - 1]].pos
    var side = Real(0)
    for k in range(n):
        var p = sc.bset.bodies[ids[k]].pos
        side = max(side, abs(p[0]) + abs(p[2]))
    return (0.5 + Real(n - 1) - top[1], side)


def _heavy(kind: Int, iters: Int) raises -> Real:
    """Penetration of a 100 kg box into a 1 kg box after 3 s."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    var lo = _box(sc, Vec3(0, 0.5, 0, 0), 1)
    var hi = _box(sc, Vec3(0, 1.5, 0, 0), 100)
    var cfg = _cfg(kind, iters)
    for _ in range(180):
        sc.step(DT, G, cfg)
    return 1.0 - (sc.bset.bodies[hi].pos[1] - sc.bset.bodies[lo].pos[1])


def _spread(kind: Int) raises -> Real:
    """Largest / smallest normal impulse of a resting box's four points
    after one frame from rest at 1 iteration."""
    var sc = ContactScene6[QuatBody6]()
    _floor(sc)
    _ = _box(sc, Vec3(0, 0.5, 0, 0), 1)
    var cfg = _cfg(kind, 1)
    cfg.substeps = 1
    for _ in range(2):
        sc.step(DT, G, cfg)
    var lo = Real(1e30)
    var hi = Real(0)
    for c in range(len(sc.cache)):
        for k in range(sc.cache[c].m.count):
            lo = min(lo, sc.cache[c].acc[k])
            hi = max(hi, sc.cache[c].acc[k])
    return hi / lo if lo > 0 else Real(1e30)


def main() raises:
    var s = Suite("contact_block")

    # ---- parity ---------------------------------------------------------------------------------------------
    var same: Bool
    var ys = List[Real]()
    for kind in range(2):
        var sc = ContactScene6[QuatBody6]()
        _floor(sc)
        var ball = sc.add_sphere(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.sphere(1, 0.5)), 0.5, False)
        sc.set_velocity(ball, Vec3(2, 0, 0.5, 0), ZERO)
        var cfg = _cfg(CONTACT_GS if kind == 0 else CONTACT_BLOCK, 4)
        for _ in range(120):
            sc.step(DT, G, cfg)
        var p = sc.bset.bodies[ball.index()].pos
        ys.append(p[0])
        ys.append(p[1])
    same = ys[0] == ys[2] and ys[1] == ys[3]
    print("  sphere, 2 s: GS x", ys[0], "y", ys[1], ";  block x", ys[2], "y", ys[3])
    s.check(same, "one-point manifolds: block is the per-point solve, bit for bit")

    var rest = List[Real]()
    for kind in range(2):
        var sc = ContactScene6[QuatBody6]()
        _floor(sc)
        var b = _box(sc, Vec3(0, 0.5, 0, 0), 1)
        var cfg = _cfg(CONTACT_GS if kind == 0 else CONTACT_BLOCK, 4)
        for _ in range(120):
            sc.step(DT, G, cfg)
        rest.append(sc.bset.bodies[b].pos[1])
    print("  box at rest, 2 s: GS y", rest[0], ";  block y", rest[1])
    s.check(abs(rest[0] - rest[1]) < 1e-5, "a resting box settles at the same height (1e-5 m)")

    # ---- integration -------------------------------------------------------------------------------------------
    var sp_gs = _spread(CONTACT_GS)
    var sp_bl = _spread(CONTACT_BLOCK)
    print("  resting box, 1 iteration: largest / smallest point impulse GS", sp_gs, ";  block", sp_bl)
    s.check(abs(sp_bl - 1) < 2e-3 and sp_gs > 1.2, "block: four equal impulses under a uniform load (0.2 %, the regularisation); GS spreads them over 20 %")
    var drift_gs = Real(0)
    var drift_bl = Real(0)
    for it in range(1, 3):
        var a = _stack(CONTACT_GS, 10, it)
        var b = _stack(CONTACT_BLOCK, 10, it)
        print("  10-box stack, iters", it, ", 4 s: top drop GS", a[0], "m, drift", a[1], ";  block", b[0], "m, drift", b[1])
        drift_gs = max(drift_gs, a[1])
        drift_bl = max(drift_bl, b[1])
        s.check(abs(a[0] - b[0]) < 2e-3, "the stack compresses alike (2 mm)")
    s.check(drift_bl < 1e-5 and drift_gs > 1e-3, "block: the stack stays straight (no sideways creep); the sequential sweep creeps over 1 mm")
    for it in range(1, 5, 3):
        print("  100 kg on 1 kg, iters", it, ", 3 s: penetration GS", _heavy(CONTACT_GS, it), "m;  block", _heavy(CONTACT_BLOCK, it))

    # ---- extremes ---------------------------------------------------------------------------------------------
    var bad = SolverConfig()
    bad.contact_solver = 7
    var raised = False
    try:
        _ = bad.validated()
    except:
        raised = True
    s.check(raised, "an unknown contact_solver is rejected")
    var ad = List[Real]()
    for kind in range(2):
        var sc = ContactScene6[QuatBody6]()
        _floor(sc)
        var b = _box(sc, Vec3(0, 0.5, 0, 0), 1)
        sc.set_adhesion(b, 5)
        var cfg = _cfg(CONTACT_GS if kind == 0 else CONTACT_BLOCK, 4)
        for _ in range(60):
            sc.step(DT, G, cfg)
        ad.append(sc.bset.bodies[b].pos[1])
    s.check(ad[0] == ad[1], "adhesion falls back to the per-point sweep (bit for bit)")
    s.finish()
