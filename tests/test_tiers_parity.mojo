# tier: system
"""Tiered simulation parity (ROADMAP 17.85).

Anchor: a plan with every body at tier 0, tier 0 = the step's own config, is
bit-identical to the untiered step -- for QuatBody6 and ScrewBody6, with
the default BVH broadphase and the persistent DBVH (`broadphase=True`), over
240 steps of a scene with several stacks (several islands, contacts, sleep)
and a falling box. Policies: DistanceTiers and CausalReach give the same plan,
hence the same world, on a scene where distance and causal reach coincide
(one cluster near the observer, one far and disconnected).
Runtime.advance_tiered with an all-zero policy equals Runtime.advance.
TieredScheduler with period 1 equals its inner scheduler; with period 3 it
runs every third tick.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import Body6, Inertia3, QuatBody6, ScrewBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from collision.bp_dbvh import DbvhBroadPhase
from collision.bp_bvh import BVHBroadPhase
from collision.broadphase import BroadPhase
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.transform import Transform
from scheduler.scheduler import System
from scheduler.sequential import SequentialScheduler
from scheduler.tiered import TieredScheduler
from gameplay.tiers import TierPolicy, DistanceTiers, CausalReach
from gameplay.runtime import Runtime, RigidBodyRef

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def _fill[BP: BroadPhase](mut sc: ContactScene6[QuatBody6, BP], far_x: Real = 12):
    _ = sc.add(QuatBody6.at_rest(_v(0, -0.5, 0), Inertia3.box(1, 40, 0.5, 40)), _v(40, 0.5, 40), True)
    for s in range(4):
        for k in range(3):
            var x = Real(s * 5) - 7.5
            _ = sc.add(
                QuatBody6.at_rest(_v(x + Real(k) * 0.05, 0.5 + Real(k) * 1.02, 2), Inertia3.box(1, 0.5, 0.5, 0.5)),
                _v(0.5, 0.5, 0.5), False,
            )
    _ = sc.add(QuatBody6.at_rest(_v(far_x, 4, -3), Inertia3.box(1, 0.4, 0.4, 0.4)), _v(0.4, 0.4, 0.4), False)


def _fill_screw(mut sc: ContactScene6[ScrewBody6]):
    """The same scene as `_fill` for the motor / screw body representation."""
    _ = sc.add(ScrewBody6.at_rest(_v(0, -0.5, 0), Inertia3.box(1, 40, 0.5, 40)), _v(40, 0.5, 40), True)
    for s in range(4):
        for k in range(3):
            var x = Real(s * 5) - 7.5
            _ = sc.add(
                ScrewBody6.at_rest(_v(x + Real(k) * 0.05, 0.5 + Real(k) * 1.02, 2), Inertia3.box(1, 0.5, 0.5, 0.5)),
                _v(0.5, 0.5, 0.5), False,
            )
    _ = sc.add(ScrewBody6.at_rest(_v(12, 4, -3), Inertia3.box(1, 0.4, 0.4, 0.4)), _v(0.4, 0.4, 0.4), False)


def _same[B: Body6, BP: BroadPhase](a: ContactScene6[B, BP], b: ContactScene6[B, BP]) -> Bool:
    if len(a.bset.bodies) != len(b.bset.bodies):
        return False
    for i in range(len(a.bset.bodies)):
        var dp = a.bset.bodies[i].position() - b.bset.bodies[i].position()
        var dv = a.bset.bodies[i].linear_velocity() - b.bset.bodies[i].linear_velocity()
        var dw = a.bset.bodies[i].omega_world() - b.bset.bodies[i].omega_world()
        for k in range(3):
            if dp[k] != 0 or dv[k] != 0 or dw[k] != 0:
                return False
        if a.bset.sleeping[i] != b.bset.sleeping[i]:
            return False
    return True


def _table[B: Body6, BP: BroadPhase](mut sc: ContactScene6[B, BP], cfg: SolverConfig) raises:
    var it = List[Int]()
    var su = List[Int]()
    var pe = List[Int]()
    it.append(cfg.iters)
    su.append(cfg.substeps)
    pe.append(1)
    it.append(2)
    su.append(1)
    pe.append(4)
    sc.set_tier_table(it, su, pe)


def _run_pair[B: Body6, BP: BroadPhase](mut base: ContactScene6[B, BP], mut tie: ContactScene6[B, BP], broadphase: Bool) raises -> Bool:
    var cfg = SolverConfig()
    cfg.broadphase = broadphase
    _table(tie, cfg)
    tie.set_body_tiers(List[Int](length=len(tie.bset.bodies), fill=0))
    var ok = True
    for _ in range(240):
        base.step(DT, G, cfg)
        tie.step(DT, G, cfg)
        if not _same(base, tie):
            ok = False
    return ok


def anchor_quat[BP: BroadPhase](broadphase: Bool) raises -> Bool:
    var base = ContactScene6[QuatBody6, BP]()
    var tie = ContactScene6[QuatBody6, BP]()
    _fill(base)
    _fill(tie)
    return _run_pair(base, tie, broadphase)


def anchor_screw() raises -> Bool:
    var base = ContactScene6[ScrewBody6]()
    var tie = ContactScene6[ScrewBody6]()
    _fill_screw(base)
    _fill_screw(tie)
    return _run_pair(base, tie, False)


@fieldwise_init
struct Tick(ComponentType):
    comptime ID: Int = 0
    var n: Int


struct CountSystem(System):
    @staticmethod
    def apply[B: StorageBackend](mut w: World[B]):
        var es = w.query1[Tick]()
        for i in range(len(es)):
            var t = w.get[Tick](es[i])
            w.set(es[i], Tick(t.n + 1))


comptime TBk = SparseSetBackend[Tick]
comptime Sched = SequentialScheduler[TBk, CountSystem]
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


struct AllZero(TierPolicy):
    def __init__(out self):
        pass

    def assign[Body: Body6](mut self, scene: ContactScene6[Body], observers: List[Vec3], step: Int) -> List[Int]:
        return List[Int](length=len(scene.bset.bodies), fill=0)


def _rt_scene(mut rt: Rt):
    _ = rt.spawn_body(QuatBody6.at_rest(_v(0, -0.5, 0), Inertia3.box(1, 20, 0.5, 20)), _v(20, 0.5, 20), True)
    for k in range(4):
        _ = rt.spawn_body(
            QuatBody6.at_rest(_v(Real(k) * 0.07, 0.5 + Real(k) * 1.02, 0), Inertia3.box(1, 0.5, 0.5, 0.5)),
            _v(0.5, 0.5, 0.5), False,
        )


def main() raises:
    var s = Suite("tiers_parity")
    s.check(anchor_quat[BVHBroadPhase[3]](False), "all-zero plan == untiered (QuatBody6, BVH)")
    s.check(anchor_quat[DbvhBroadPhase[3]](True), "all-zero plan == untiered (QuatBody6, persistent DBVH)")
    s.check(anchor_screw(), "all-zero plan == untiered (ScrewBody6, BVH)")

    # distance and causal reach coincide: near stacks at x in [-7.5, 7.5],
    # one far lone box at x = 40 (no contact with anything but the floor)
    var cfg = SolverConfig()
    var a = ContactScene6[QuatBody6]()
    var b = ContactScene6[QuatBody6]()
    _fill(a, 40)
    _fill(b, 40)
    _table(a, cfg)
    _table(b, cfg)
    var obs = List[Vec3]()
    obs.append(_v(0, 0, 2))
    var radii = List[Real]()
    radii.append(15)
    var dist = DistanceTiers(radii^, 1)
    var depths = List[Int]()
    depths.append(10)
    var causal = CausalReach(15, depths^)
    var plans_equal = True
    var any_coarse = False
    for _ in range(180):
        var pa = dist.assign(a, obs, a.step_index)
        var pb = causal.assign(b, obs, b.step_index)
        for i in range(1, len(pa)):  # slot 0 is the static floor
            if pa[i] != pb[i]:
                plans_equal = False
            if pa[i] > 0:
                any_coarse = True
        a.set_body_tiers(pa)
        b.set_body_tiers(pb)
        a.step(DT, G, cfg)
        b.step(DT, G, cfg)
    s.check(any_coarse, "the far box is coarse")
    s.check(plans_equal, "DistanceTiers and CausalReach agree when distance = causal reach")
    s.check(_same(a, b), "same plans -> same world")

    # Runtime: advance_tiered with an all-zero policy == advance
    var r1 = Rt(DT, G)
    var r2 = Rt(DT, G)
    _rt_scene(r1)
    _rt_scene(r2)
    _table(r2.scene, r2.cfg)
    var pol = AllZero()
    var none = List[Vec3]()
    for f in range(90):
        var fdt = Float64(DT) * (1.5 if f % 3 == 0 else 0.75)
        _ = r1.advance(fdt)
        _ = r2.advance_tiered(fdt, pol, none)
    s.check(_same(r1.scene, r2.scene), "Runtime.advance_tiered(all zero) == Runtime.advance")

    # TieredScheduler
    var w1 = World[TBk]()
    var w2 = World[TBk]()
    var w3 = World[TBk]()
    var e1 = w1.spawn()
    w1.set(e1, Tick(0))
    var e2 = w2.spawn()
    w2.set(e2, Tick(0))
    var e3 = w3.spawn()
    w3.set(e3, Tick(0))
    var plain = Sched()
    var t1 = TieredScheduler[Sched]()
    var t3 = TieredScheduler[Sched]()
    t3.set_rate(3, 1)
    for _ in range(30):
        plain.tick(w1)
        t1.tick(w2)
        t3.tick(w3)
    s.eqi(w2.get[Tick](e2).n, w1.get[Tick](e1).n, "period 1 == inner scheduler")
    s.eqi(w3.get[Tick](e3).n, 10, "period 3: every third tick (10 of 30)")
    s.eqi(t3.ticks_run, 10, "ticks_run counts the runs")
    var raised = False
    try:
        t3.set_rate(0)
    except:
        raised = True
    s.check(raised, "period 0 raises")
    s.finish()
