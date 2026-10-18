# tier: integration
"""Batch x reverse AD (ROADMAP 17.84, `geometry.field.RevBatch` /
`BatchTape` / `rev_batch_seed`).

8 worlds of test_diffsolver's slide-to-roll scene (a 0.5 m sphere on the
ground, launch speed 0.5 k m/s in world k, friction 0.5) stepped 1.5 s in
ONE `SphereWorld[RevBatch[8]]`; one backward sweep gives d x / d vx0 and
d x / d mu for all 8.

  1. Ordinary: lane k of both gradients and of the primal x matches a
     `RevReal` run of world k (measured: bit for bit; asserted: gradients
     within 1e-4 of the largest, primal exact). The tape types' primal
     differs from `RealF` / `BatchReal` by 1 ulp (1.2e-7, printed): the
     taped arithmetic is lowered without the FMA contractions the plain
     types get.
  2. Integration: the tape has as many nodes as one `RevReal` world's
     (printed): eight worlds cost one recording, not eight.
  3. Extreme: a NaN launch speed in world 3 leaves the other lanes'
     gradients bit-identical to the clean run.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3, WorldType
from geometry.field import SolverField, RevReal, Tape, rev_seed, BatchReal, RevBatch, BatchTape, rev_batch_seed
from physics.diffsolver import SphereWorld, V3

comptime DT: Real = 1.0 / 60.0
comptime W = 8
comptime FRAMES = 90


def run[F: SolverField](vx0: F, mu: F) -> SphereWorld[F]:
    var w = SphereWorld[F]()
    w.mu = mu
    _ = w.add_plane(Vec3(0, 1, 0, 0), 0)
    _ = w.add_sphere(V3[F](F.zero(), F.const(0.5), F.zero()), V3[F](vx0, F.zero(), F.zero()), F.const(0.5), F.const(1))
    for _ in range(FRAMES):
        w.step(DT)
    return w^


def batch_grads(v: SIMD[WorldType, W]) -> Tuple[SIMD[WorldType, W], SIMD[WorldType, W], SIMD[WorldType, W], Int]:
    var t = BatchTape[W]()
    var bv = rev_batch_seed(t, v)
    var bm = rev_batch_seed(t, SIMD[WorldType, W](0.5))
    var w = run[RevBatch[W]](bv, bm)
    var a = t.grad(w.bodies[0].pos.x.idx)
    return (w.bodies[0].pos.x.v, a[bv.idx], a[bm.idx], len(t.nodes))


def main() raises:
    var s = Suite("rev_batch")
    var v = SIMD[WorldType, W](0)
    for k in range(W):
        v[k] = Real(0.5) * Real(k)
    var g = batch_grads(v)
    var big = Real(0)
    var worst = Real(0)
    var nodes1 = 0
    for k in range(W):
        var t = Tape()
        var rv = rev_seed(t, v[k])
        var rm = rev_seed(t, 0.5)
        var w = run[RevReal](rv, rm)
        var a = t.grad(w.bodies[0].pos.x.idx)
        nodes1 = len(t.nodes)
        big = max(big, max(abs(a[rv.idx]), abs(a[rm.idx])))
        worst = max(worst, max(abs(a[rv.idx] - g[1][k]), abs(a[rm.idx] - g[2][k])))
        if k == 5:
            print("world 5: RevReal dx/dvx0", a[rv.idx], "dx/dmu", a[rm.idx], ";  RevBatch lane 5", g[1][k], g[2][k])
    var plain = run[BatchReal[W]](BatchReal[W](v), BatchReal[W].const(0.5))
    var prim = True
    var dvb = Real(0)
    for k in range(W):
        var t2 = Tape()
        var r2 = run[RevReal](rev_seed(t2, v[k]), rev_seed(t2, 0.5))
        prim = prim and r2.bodies[0].pos.x.v == g[0][k] and len(t2.nodes) == nodes1
        dvb = max(dvb, abs(plain.bodies[0].pos.x.v[k] - g[0][k]))
    print("primal: RevBatch vs BatchReal[8] (and RealF) worst lane difference", dvb)
    print("8 worlds: worst |RevBatch lane - RevReal world| / max gradient", worst / big, ";  tape nodes: batch", g[3], " one RevReal world", nodes1)
    s.check(worst <= 1e-4 * big, "lane k == RevReal world k (1e-4 of the largest gradient)")
    s.check(prim, "primal lanes == RevReal world k, bit for bit")
    s.check(g[3] == nodes1, "one tape for 8 worlds: as many nodes as one world")

    var vn = v
    vn[3] = Real(0) / Real(0)
    var gn = batch_grads(vn)
    var iso = True
    for k in range(W):
        if k != 3:
            iso = iso and gn[1][k] == g[1][k] and gn[2][k] == g[2][k]
    s.check(iso and not isfinite(gn[1][3]), "a NaN world leaves the other lanes' gradients bit-identical")
    s.finish()
