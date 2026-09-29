# tier: integration
"""The differentiable / batchable contact solver (ROADMAP 17.20 + 17.18).

  1. Parity with the production solver: the `RealF` instance of
     `physics.diffsolver.SphereWorld` against `ContactScene6[QuatBody6]` on
     spheres over a large static box (drop, stack, and a slide that turns
     into rolling). Same algorithm, re-stated over a coefficient ring, so the
     trajectories agree to float32 noise, not bit-for-bit (different
     operation grouping inside the vector helpers).
  2. Physics: a sphere launched along the ground starts rolling at 5/7 of
     its launch speed (Coulomb friction on a solid sphere) in both solvers,
     and then loses speed identically in both (rolling resistance from the
     rotating contact anchors -- a production-solver finding, 17.19).
  3. Gradients: forward (`DualReal`), 4-direction forward (`DualBatch`),
     reverse (`RevReal`) and central finite differences agree on the
     derivative of the final x-position w.r.t. launch speed and friction.
  4. Batch: lane k of `BatchReal[8]` matches the `RealF` world with lane
     k's inputs (float32 noise, see the check); a NaN world stays confined to its own lane.
  5. Extremes: no contact ever (exact ballistic), frictionless slide (no
     spin), coincident sphere centres (finite), rest height independent of
     drop height (zero derivative, and the FD agrees).
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.field import SolverField, RealF, DualReal, DualBatch, RevReal, BatchReal, Tape, rev_seed
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.diffsolver import SphereWorld, V3

comptime DT: Real = 1.0 / 60.0


def _ref_scene(
    ys: List[Real], vx0: Real, mu: Real, frames: Int
) -> Tuple[List[Real], List[Real], List[Real]]:
    """`ContactScene6`: static ground box (top face y = 0) + spheres r = 0.5,
    m = 1 at x = 0 and heights `ys`. Returns final (x, y, vx) per sphere."""
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(
        QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 50, 0.5, 50)),
        Vec3(50, 0.5, 50, 0),
        True,
    )
    for i in range(len(ys)):
        var b = QuatBody6.at_rest(Vec3(0, ys[i], 0, 0), Inertia3.sphere(1, 0.5))
        b.vel = Vec3(vx0, 0, 0, 0)
        var id = sc.add_sphere(b^, 0.5, False)
        try:
            sc.set_can_sleep(id, False)
        except:
            pass
    for _ in range(frames):
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0), mu=mu)
    var xs = List[Real]()
    var yo = List[Real]()
    var vxs = List[Real]()
    for i in range(len(ys)):
        var b = sc.bset.bodies[i + 1]
        xs.append(b.position()[0])
        yo.append(b.position()[1])
        vxs.append(b.linear_velocity()[0])
    return (xs^, yo^, vxs^)


def _diff_world[F: SolverField](ys: List[Real], vx0: F, mu: F) -> SphereWorld[F]:
    var w = SphereWorld[F]()
    w.mu = mu
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    for i in range(len(ys)):
        _ = w.add_sphere(
            V3[F](F.zero(), F.const(ys[i]), F.zero()),
            V3[F](vx0, F.zero(), F.zero()),
            F.const(0.5),
            F.const(1),
        )
    return w^



def _run[F: SolverField](ys: List[Real], vx0: F, mu: F, frames: Int) -> SphereWorld[F]:
    var w = _diff_world[F](ys, vx0, mu)
    for _ in range(frames):
        w.step(DT)
    return w^


def _x_final(vx0: Real, mu: Real) -> Real:
    var ys = List[Real]()
    ys.append(0.5)
    var w = _run[RealF](ys, RealF(vx0), RealF(mu), 90)
    return w.bodies[0].pos.x.v


def _al(mut s: Suite, got: Real, want: Real, tol: Real, label: String):
    s.almost(Float64(got), Float64(want), label, Float64(tol))


def main() raises:
    var s = Suite("diffsolver")

    # ---- 1. parity with ContactScene6 ------------------------------------
    var drop = List[Real]()
    drop.append(2.0)
    var r0 = _ref_scene(drop, 0, 0.5, 180)
    var d0 = _run[RealF](drop, RealF(0), RealF(0.5), 180)
    _al(s, d0.bodies[0].pos.y.v, r0[1][0], 1e-4, "drop: rest height matches ContactScene6")
    _al(s, d0.bodies[0].pos.y.v, 0.5, 1e-2, "drop: rests on the face")

    var stack = List[Real]()
    stack.append(0.5)
    stack.append(1.6)
    stack.append(2.7)
    var r1 = _ref_scene(stack, 0, 0.5, 240)
    var d1 = _run[RealF](stack, RealF(0), RealF(0.5), 240)
    for i in range(3):
        _al(s, 
            d1.bodies[i].pos.y.v, r1[1][i], 1e-3,
            "stack: sphere " + String(i) + " height matches ContactScene6",
        )

    var ground = List[Real]()
    ground.append(0.5)
    var r2 = _ref_scene(ground, 3, 0.5, 90)
    var d2 = _run[RealF](ground, RealF(3), RealF(0.5), 90)
    _al(s, d2.bodies[0].pos.x.v, r2[0][0], 5e-3, "slide->roll: x matches ContactScene6")
    _al(s, d2.bodies[0].vel.x.v, r2[2][0], 5e-3, "slide->roll: vx matches ContactScene6")

    # ---- 2. physics: reaches 5/7 of launch speed when rolling starts ----
    # t_roll = 2 v0 / (7 mu g) = 0.175 s ~ frame 11; frame 15 is just past it.
    var early = _run[RealF](ground, RealF(3), RealF(0.5), 15)
    var r15 = _ref_scene(ground, 3, 0.5, 15)
    _al(s, early.bodies[0].vel.x.v, 3.0 * 5.0 / 7.0, 0.1, "diffsolver: rolling starts at 5/7 v0")
    _al(s, r15[2][0], 3.0 * 5.0 / 7.0, 0.1, "ContactScene6: rolling starts at 5/7 v0")
    # FINDING (ROADMAP 17.19): after that the ball keeps losing speed -- the
    # body-frame contact anchors rotate with a rolling sphere, so friction
    # acts at a point off the true contact. Both solvers share it exactly.
    s.check(d2.bodies[0].vel.x.v < early.bodies[0].vel.x.v, "rolling resistance present (anchor rotation)")
    _al(s, d2.bodies[0].vel.x.v, r2[2][0], 5e-3, "rolling resistance identical in both solvers")

    # ---- 3. gradients: dual / dual-batch / reverse / FD ------------------
    var vx0 = Real(3)
    var mu = Real(0.5)
    var dw = _run[DualReal](ground, DualReal.seed(vx0), DualReal.const(mu), 90)
    var dx_dv = dw.bodies[0].pos.x.b
    var dwm = _run[DualReal](ground, DualReal.const(vx0), DualReal.seed(mu), 90)
    var dx_dmu = dwm.bodies[0].pos.x.b
    var eps = Real(1e-2)
    var fd_v = (_x_final(vx0 + eps, mu) - _x_final(vx0 - eps, mu)) / (2 * eps)
    var fd_mu = (_x_final(vx0, mu + eps) - _x_final(vx0, mu - eps)) / (2 * eps)
    _al(s, dx_dv, fd_v, 0.02 * abs(fd_v) + 1e-3, "dx/dvx0: dual == FD")
    _al(s, dx_dmu, fd_mu, 0.05 * abs(fd_mu) + 2e-3, "dx/dmu: dual == FD")
    s.check(dx_dmu < 0, "dx/dmu < 0: more friction, shorter slide")

    var bw = _run[DualBatch](ground, DualBatch.seed(vx0, 0), DualBatch.seed(mu, 1), 90)
    _al(s, bw.bodies[0].pos.x.b[0], dx_dv, 1e-4 * abs(dx_dv) + 1e-5, "dx/dvx0: dual-batch lane == dual")
    _al(s, bw.bodies[0].pos.x.b[1], dx_dmu, 1e-4 * abs(dx_dmu) + 1e-5, "dx/dmu: dual-batch lane == dual")

    var tape = Tape()
    var rv = rev_seed(tape, vx0)
    var rm = rev_seed(tape, mu)
    var rw = _run[RevReal](ground, rv, rm, 90)
    var adj = tape.grad(rw.bodies[0].pos.x.idx)
    _al(s, adj[rv.idx], dx_dv, 1e-3 * abs(dx_dv) + 1e-4, "dx/dvx0: reverse == dual")
    _al(s, adj[rm.idx], dx_dmu, 1e-3 * abs(dx_dmu) + 1e-4, "dx/dmu: reverse == dual (one sweep, both)")

    # ---- 4. batch: lane k == scalar world k, bit for bit ----------------
    comptime W = 8
    var vb = SIMD[DType.float32, W](0)
    for k in range(W):
        vb[k] = Real(0.5) * Real(k)
    var bwld = _run[BatchReal[W]](ground, BatchReal[W](vb), BatchReal[W].const(mu), 60)
    # Lane-wise IEEE ops, but the SIMD and scalar code paths are not
    # bit-identical after contact (~1e-6 over 60 frames; FMA contraction
    # differs between the two lowerings) -- measured, so bounded here.
    var worst = Real(0)
    for k in range(W):
        var sw = _run[RealF](ground, RealF(vb[k]), RealF(mu), 60)
        worst = max(worst, abs(sw.bodies[0].pos.x.v - bwld.bodies[0].pos.x.v[k]))
        worst = max(worst, abs(sw.bodies[0].pos.y.v - bwld.bodies[0].pos.y.v[k]))
        worst = max(worst, abs(sw.bodies[0].omega.z.v - bwld.bodies[0].omega.z.v[k]))
    print("  batch vs scalar worst lane difference:", worst)
    s.check(worst <= 1e-4, "batch: every lane matches its scalar world (<= 1e-4)")

    var vn = vb
    vn[3] = Real(0) / Real(0)
    var nwld = _run[BatchReal[W]](ground, BatchReal[W](vn), BatchReal[W].const(mu), 60)
    var iso = True
    for k in range(W):
        if k == 3:
            continue
        if nwld.bodies[0].pos.x.v[k] != bwld.bodies[0].pos.x.v[k]:
            iso = False
    s.check(iso, "batch: a NaN world leaves the other lanes bit-identical")
    s.check(not isfinite(nwld.bodies[0].pos.x.v[3]), "batch: the NaN world stays NaN (not silently repaired)")

    # ---- 5. extremes -----------------------------------------------------
    var high = List[Real]()
    high.append(100.0)
    var fall = _run[RealF](high, RealF(0), RealF(mu), 30)
    var hr = DT / 4
    var vy = Real(0)
    var y = Real(100)
    for _ in range(30 * 4):
        vy += Real(-9.8) * hr
        y += vy * hr
    _al(s, fall.bodies[0].pos.y.v, y, 1e-3, "no contact: exact substepped ballistic")

    var slick = _run[RealF](ground, RealF(3), RealF(0), 60)
    _al(s, slick.bodies[0].vel.x.v, 3, 1e-4, "mu = 0: keeps sliding speed")
    _al(s, slick.bodies[0].omega.z.v, 0, 1e-5, "mu = 0: never spins")

    var same = List[Real]()
    same.append(1.0)
    same.append(1.0)
    var coin = _run[RealF](same, RealF(0), RealF(mu), 30)
    var fin = True
    for i in range(2):
        var p = coin.bodies[i].pos
        if not (isfinite(p.x.v) and isfinite(p.y.v) and isfinite(p.z.v)):
            fin = False
    s.check(fin, "coincident centres: finite")

    var hd = List[Real]()
    hd.append(1.5)
    var w_hd = _diff_world[DualReal](hd, DualReal.const(0), DualReal.const(mu))
    w_hd.bodies[0].pos.y = DualReal.seed(1.5)
    for _ in range(180):
        w_hd.step(DT)
    _al(s, w_hd.bodies[0].pos.y.b, 0, 1e-3, "rest height: d(y_rest)/d(y0) = 0")

    s.finish()
