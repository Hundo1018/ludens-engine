"""The differentiable contact solver as two seams (ROADMAP 17.20, 17.18).

World layout (17.18): N independent worlds, each one sphere rolling on a
plane, stepped (a) one `RealF` world after another, (b) eight at a time in
the SIMD lanes of `BatchReal[8]`, and (c) the same batches fanned out over
cores. Lane k of a batch is bit-identical to scalar world k
(`test_diffsolver`), so the rows compare the same computation in three
layouts. N = 1 is the control: a batch of one world pays for eight lanes.

Gradient (17.20): the derivative of the final position w.r.t. NP launch
parameters (one per sphere, NP spheres in one world), by central finite
differences (2·NP rollouts), forward mode (NP `DualReal` rollouts, or NP/4
`DualBatch` ones) and reverse mode (one `RevReal` rollout plus one tape
sweep). Reverse is flat in NP by construction; the interesting number is
where its taping overhead is paid back.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from geometry.field import (
    SolverField, RealF, DualReal, DualBatch, RevReal, BatchReal, Tape, rev_seed,
)
from physics.diffsolver import SphereWorld, V3, step_worlds_parallel

comptime DT: Real = 1.0 / 60.0
comptime FRAMES = 30
comptime REPS = 3
comptime GFRAMES = 10  # gradient rows: the tape grows with frames x pairs


def _world[F: SolverField](vx: F) -> SphereWorld[F]:
    var w = SphereWorld[F]()
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    _ = w.add_sphere(
        V3[F](F.zero(), F.const(0.5), F.zero()),
        V3[F](vx, F.zero(), F.zero()),
        F.const(0.5),
        F.const(1),
    )
    return w^


def _layout_rows(mut t: BenchTable, n: Int) raises:
    var best = Int.MAX
    for _ in range(REPS):
        var ws = List[SphereWorld[RealF]]()
        for k in range(n):
            ws.append(_world[RealF](RealF(Real(k % 7) * 0.5)))
        var t0 = Int(perf_counter_ns())
        for k in range(n):
            for _ in range(FRAMES):
                ws[k].step(DT)
        var d = Int(perf_counter_ns()) - t0
        keep(ws[0].bodies[0].pos.x.v)
        best = min(best, d)
    t.add("scalar worlds, sequential", n, "world-step", best, n * FRAMES)

    var nb = (n + 7) // 8
    var b2 = Int.MAX
    for _ in range(REPS):
        var ws = List[SphereWorld[BatchReal[8]]]()
        for k in range(nb):
            ws.append(_world[BatchReal[8]](BatchReal[8].const(Real(k % 7) * 0.5)))
        var t0 = Int(perf_counter_ns())
        for k in range(nb):
            for _ in range(FRAMES):
                ws[k].step(DT)
        var d = Int(perf_counter_ns()) - t0
        keep(ws[0].bodies[0].pos.x.v[0])
        b2 = min(b2, d)
    t.add("BatchReal[8] lanes, sequential", n, "world-step", b2, n * FRAMES)

    var b3 = Int.MAX
    for _ in range(REPS):
        var ws = List[SphereWorld[BatchReal[8]]]()
        for k in range(nb):
            ws.append(_world[BatchReal[8]](BatchReal[8].const(Real(k % 7) * 0.5)))
        var t0 = Int(perf_counter_ns())
        step_worlds_parallel[8](ws, DT, FRAMES)
        var d = Int(perf_counter_ns()) - t0
        keep(ws[0].bodies[0].pos.x.v[0])
        b3 = min(b3, d)
    t.add("BatchReal[8] lanes x cores", n, "world-step", b3, n * FRAMES)


def _chain[F: SolverField](vx: List[F]) -> SphereWorld[F]:
    """NP spheres in a row on the plane, each with its own launch speed."""
    var w = SphereWorld[F]()
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    for i in range(len(vx)):
        _ = w.add_sphere(
            V3[F](F.const(Real(i) * 1.5), F.const(0.5), F.zero()),
            V3[F](vx[i], F.zero(), F.zero()),
            F.const(0.5),
            F.const(1),
        )
    return w^


def _loss[F: SolverField](w: SphereWorld[F]) -> F:
    var s = F.zero()
    for i in range(len(w.bodies)):
        s = s + w.bodies[i].pos.x
    return s


def _grad_rows(mut t: BenchTable, np: Int) raises:
    var base = List[Real]()
    for i in range(np):
        base.append(1 + Real(i % 5) * 0.25)

    var best = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for p in range(np):
            for sgn in range(2):
                var v = List[RealF]()
                for i in range(np):
                    var e = Real(1e-2) if i == p else Real(0)
                    v.append(RealF(base[i] + (e if sgn == 0 else -e)))
                var w = _chain[RealF](v)
                for _ in range(GFRAMES):
                    w.step(DT)
                keep(_loss(w).v)
        best = min(best, Int(perf_counter_ns()) - t0)
    t.add("central FD (2·NP rollouts)", np, "gradient", best, 1)

    var b2 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        for p in range(np):
            var v = List[DualReal]()
            for i in range(np):
                v.append(DualReal.seed(base[i]) if i == p else DualReal.const(base[i]))
            var w = _chain[DualReal](v)
            for _ in range(GFRAMES):
                w.step(DT)
            keep(_loss(w).b)
        b2 = min(b2, Int(perf_counter_ns()) - t0)
    t.add("forward DualReal (NP rollouts)", np, "gradient", b2, 1)

    var b3 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var p0 = 0
        while p0 < np:
            var v = List[DualBatch]()
            for i in range(np):
                var lane = i - p0
                v.append(
                    DualBatch.seed(base[i], lane) if lane >= 0 and lane < 4 else DualBatch.const(base[i])
                )
            var w = _chain[DualBatch](v)
            for _ in range(GFRAMES):
                w.step(DT)
            keep(_loss(w).b[0])
            p0 += 4
        b3 = min(b3, Int(perf_counter_ns()) - t0)
    t.add("forward DualBatch (NP/4 rollouts)", np, "gradient", b3, 1)

    var b4 = Int.MAX
    for _ in range(REPS):
        var t0 = Int(perf_counter_ns())
        var tape = Tape()
        var v = List[RevReal]()
        for i in range(np):
            v.append(rev_seed(tape, base[i]))
        var w = _chain[RevReal](v)
        for _ in range(GFRAMES):
            w.step(DT)
        var g = tape.grad(_loss(w).idx)
        keep(g[v[0].idx])
        b4 = min(b4, Int(perf_counter_ns()) - t0)
    t.add("reverse RevReal (1 rollout + sweep)", np, "gradient", b4, 1)


def main() raises:
    var t = BenchTable("Batched worlds: scalar vs SIMD lanes vs lanes x cores (30 frames, 1 sphere/world)")
    for n in [1, 8, 64, 512, 4096]:
        _layout_rows(t, n)
    t.print_report()
    print("")
    var g = BenchTable("Gradient of sum(x_final) w.r.t. NP launch speeds (10 frames, NP spheres; every sphere pair is carried, O(NP^2))")
    for np in [1, 2, 4, 8, 16]:
        _grad_rows(g, np)
    g.print_report()
