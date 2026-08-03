"""Differentiable-simulation benchmark: what a gradient costs, and what the
Field abstraction costs.

Table 1 — gradient of the landing state w.r.t. launch velocity (2 params)
through the Field-generic rollout (`physics/diffsim.mojo`, gradient
correctness in `test_diffsim`): a plain rollout as baseline, then the same
2-parameter gradient obtained three ways — central finite differences
(4 rollouts), forward-mode `DualReal` (2 rollouts, one direction each), and
`DualBatch` (ONE rollout, both directions in SIMD lanes). ns/op is normalized
per *logical* simulation step, so the rows compare total gradient cost
directly.

Table 2 — PGA motor sandwich `M P ~M` through each coefficient carrier: the
specialized `Motor3.apply_point` (Real SIMD), the Field-generic
`GMV[3,0,1,RealF]` (prices the Field wrapper), `DualReal` (+1 derivative
direction) and `DualBatch` (+4 directions). Value-lane parity vs the
specialized multivector is `test_gmv_ad`.

Run: taskset -c 3 pixi run mojo run -I build benchmarks/bench_diffsim.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, measure
from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real, Vec3, normalize
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.field import Field, RealF, DualReal, DualBatch, Tape, RevReal, rev_seed
from geometry.gmv import GMV
from physics.diffsim import rollout2, rollout_ctrl, rollout_ctrl_adjoint

# PGA3 point-trivector blade masks (same convention as geometry/motor.mojo)
comptime _E123 = 0b0111
comptime _T230 = 0b1110
comptime _T130 = 0b1101
comptime _T120 = 0b1011


def bench_gradient(mut table: BenchTable):
    comptime STEPS = 2000
    comptime DT: Real = 0.001
    comptime VX: Real = 3.0
    comptime VY: Real = 5.0
    comptime Y0: Real = 1.0
    comptime H: Real = 1e-4

    @parameter
    def plain():
        var s = rollout2[RealF](RealF(VX), RealF(VY), Y0, STEPS, DT)
        keep(s.x.value())

    @parameter
    def central():
        # d(x_land)/d(vx0) and d(x_land)/d(vy0) via 4 shifted rollouts
        var xp = rollout2[RealF](RealF(VX + H), RealF(VY), Y0, STEPS, DT)
        var xm = rollout2[RealF](RealF(VX - H), RealF(VY), Y0, STEPS, DT)
        var yp = rollout2[RealF](RealF(VX), RealF(VY + H), Y0, STEPS, DT)
        var ym = rollout2[RealF](RealF(VX), RealF(VY - H), Y0, STEPS, DT)
        keep((xp.x.value() - xm.x.value()) / (2 * H))
        keep((yp.x.value() - ym.x.value()) / (2 * H))

    @parameter
    def dual():
        var a = rollout2[DualReal](DualReal.seed(VX), DualReal.const(VY), Y0, STEPS, DT)
        var b = rollout2[DualReal](DualReal.const(VX), DualReal.seed(VY), Y0, STEPS, DT)
        keep(a.x.b)
        keep(b.x.b)

    @parameter
    def batch():
        var s = rollout2[DualBatch](
            DualBatch.seed(VX, 0), DualBatch.seed(VY, 1), Y0, STEPS, DT
        )
        keep(s.x.b[0])
        keep(s.x.b[1])

    @parameter
    def reverse():
        # 1 taped rollout + 1 backward sweep gives BOTH components; the cost
        # is tape recording (List appends) — but unlike forward mode it stays
        # ONE rollout no matter how many inputs are seeded.
        var tape = Tape()
        var s = rollout2[RevReal](
            rev_seed(tape, VX), rev_seed(tape, VY), Y0, STEPS, DT
        )
        var adj = tape.grad(s.x.idx)
        keep(adj[0])
        keep(adj[1])

    table.add("realf baseline (1 rollout)", STEPS, "rollout", measure[plain](3, 20), STEPS)
    table.add("central diff (4 rollouts)", STEPS, "grad(2)", measure[central](3, 20), STEPS)
    table.add("dualreal (2 rollouts)", STEPS, "grad(2)", measure[dual](3, 20), STEPS)
    table.add("dualbatch (1 rollout)", STEPS, "grad(2)", measure[batch](3, 20), STEPS)
    table.add("reverse tape (1 rollout+sweep)", STEPS, "grad(2)", measure[reverse](3, 20), STEPS)


def bench_gradient_n[NP: Int, BURST: Int](mut table: BenchTable):
    """`NP` control parameters (`rollout_ctrl`, parity in `test_diffsim` #8):
    the rollout-count scaling the 2-param table cannot show — differences pay
    N+1 rollouts, DualBatch ⌈N/4⌉ (lane cap), the reverse tape one.

    Callers sweep NP with `NP * BURST` held at 2000, so the PRIMAL work is
    identical in every row and the only thing varying is how each method's
    overhead scales with the parameter count — which is what locates the
    forward/reverse crossover empirically instead of by extrapolation."""
    comptime DT: Real = 0.001

    var base = List[Real]()
    for k in range(NP):
        base.append(0.3 + 0.05 * Real(k))

    @parameter
    def fd_forward():
        # N+1 rollouts: baseline + one bumped rollout per parameter
        comptime H: Real = 1e-3
        var u0 = List[RealF]()
        for j in range(NP):
            u0.append(RealF(base[j]))
        var s0 = rollout_ctrl[RealF](u0, BURST, DT)
        var acc = Real(0)
        for k in range(NP):
            var up = List[RealF]()
            for j in range(NP):
                up.append(RealF(base[j] + (H if j == k else Real(0))))
            var sp = rollout_ctrl[RealF](up, BURST, DT)
            acc += (sp.x.value() - s0.x.value()) / H
        keep(acc)

    @parameter
    def batch_chunks():
        # ceil(NP/4) rollouts, four seeded lanes each
        comptime CHUNKS = (NP + 3) // 4
        var acc = Real(0)
        for chunk in range(CHUNKS):
            var ub = List[DualBatch]()
            for j in range(NP):
                if j // 4 == chunk:
                    ub.append(DualBatch.seed(base[j], j % 4))
                else:
                    ub.append(DualBatch.const(base[j]))
            var sb = rollout_ctrl[DualBatch](ub, BURST, DT)
            for l in range(4):
                acc += sb.x.b[l]
        keep(acc)

    @parameter
    def adjoint_s2s():
        # the routine a source-to-source tool emits: explicit backward pass,
        # no node list, one checkpoint BIT per step instead of a node per op
        var g = List[Real]()
        var xf = rollout_ctrl_adjoint(base, BURST, DT, g)
        keep(xf)
        var acc = Real(0)
        for j in range(NP):
            acc += g[j]
        keep(acc)

    @parameter
    def reverse_tape():
        # ONE rollout + one backward sweep, N-independent
        var tape = Tape()
        var ur = List[RevReal]()
        for j in range(NP):
            ur.append(rev_seed(tape, base[j]))
        var sr = rollout_ctrl[RevReal](ur, BURST, DT)
        var adj = tape.grad(sr.x.idx)
        var acc = Real(0)
        for j in range(NP):
            acc += adj[ur[j].idx]
        keep(acc)

    comptime TOTAL = NP * BURST
    comptime CHUNKS = (NP + 3) // 4
    comptime G = "grad(" + String(NP) + ")"
    table.add(
        "fd forward (" + String(NP + 1) + " rollouts)",
        TOTAL, G, measure[fd_forward](3, 20), TOTAL,
    )
    table.add(
        "dualbatch (" + String(CHUNKS) + " rollouts)",
        TOTAL, G, measure[batch_chunks](3, 20), TOTAL,
    )
    table.add(
        "reverse tape (1 rollout)", TOTAL, G, measure[reverse_tape](3, 20), TOTAL
    )
    table.add(
        "adjoint s2s (emitted)", TOTAL, G, measure[adjoint_s2s](3, 20), TOTAL
    )


def to_gmv[F: Field](m: Motor3) -> GMV[3, 0, 1, F]:
    var mv = m.to_mv()
    var g = GMV[3, 0, 1, F]()
    for i in range(16):
        g.c[i] = F.const(mv.c[i])
    return g^


def sandwich_x[F: Field](m: GMV[3, 0, 1, F], pt: Vec3) -> Real:
    """`M P ~M` on the point trivector, generically over the coefficient Field;
    returns the transformed x (same embedding as `Motor3.apply_point`)."""
    var P = GMV[3, 0, 1, F]()
    P.c[_E123] = F.const(1)
    P.c[_T230] = F.const(-pt[0])
    P.c[_T130] = F.const(pt[1])
    P.c[_T120] = F.const(-pt[2])
    var R = m * P * m.reverse()
    return -(R.c[_T230].value()) / R.c[_E123].value()


def bench_sandwich(mut table: BenchTable):
    comptime K = 1024
    var rng = SplitMix64.seeded(7)

    var motors = List[Motor3](capacity=K)
    var gr = List[GMV[3, 0, 1, RealF]](capacity=K)
    var gd = List[GMV[3, 0, 1, DualReal]](capacity=K)
    var gb = List[GMV[3, 0, 1, DualBatch]](capacity=K)
    for _ in range(K):
        var axis = normalize(
            Vec3(
                Real(rng.next_f32()) + 0.1,
                Real(rng.next_f32()) + 0.2,
                Real(rng.next_f32()) + 0.3,
            )
        )
        var q = Quat.from_axis_angle(axis, Real(rng.next_f32()) * 3 - 1.5)
        var t = Vec3(
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
            Real(rng.next_f32()) * 2 - 1,
        )
        var m = Motor3.from_quat_translation(q, t)
        motors.append(m)
        gr.append(to_gmv[RealF](m))
        gd.append(to_gmv[DualReal](m))
        gb.append(to_gmv[DualBatch](m))

    var p = Vec3(0.7, -0.3, 1.1)

    @parameter
    def s_motor():
        var acc = Real(0)
        for i in range(K):
            acc += motors[i].apply_point(p)[0]
        keep(acc)

    @parameter
    def s_realf():
        var acc = Real(0)
        for i in range(K):
            acc += sandwich_x(gr[i], p)
        keep(acc)

    @parameter
    def s_dual():
        var acc = Real(0)
        for i in range(K):
            acc += sandwich_x(gd[i], p)
        keep(acc)

    @parameter
    def s_batch():
        var acc = Real(0)
        for i in range(K):
            acc += sandwich_x(gb[i], p)
        keep(acc)

    table.add("motor3 (specialized)", K, "sandwich", measure[s_motor](3, 20), K)
    table.add("gmv[realf]", K, "sandwich", measure[s_realf](3, 20), K)
    table.add("gmv[dualreal] (+1 dir)", K, "sandwich", measure[s_dual](3, 20), K)
    table.add("gmv[dualbatch] (+4 dirs)", K, "sandwich", measure[s_batch](3, 20), K)


def main() raises:
    var t1 = BenchTable("Differentiable rollout — gradient cost (2000 steps, 2 params)")
    bench_gradient(t1)
    t1.print_report()

    # Parameter-count sweep at CONSTANT primal work (NP x BURST = 2000 steps
    # in every row): the forward/reverse crossover measured, not extrapolated.
    var tn = BenchTable(
        "Differentiable rollout — parameter-count sweep (NP x BURST = 2000 steps, constant primal work)"
    )
    bench_gradient_n[8, 250](tn)
    bench_gradient_n[20, 100](tn)
    bench_gradient_n[40, 50](tn)
    bench_gradient_n[100, 20](tn)
    bench_gradient_n[200, 10](tn)
    tn.print_report()

    var t2 = BenchTable("GA motor sandwich — specialized vs Field-generic vs AD carriers")
    bench_sandwich(t2)
    t2.print_report()
