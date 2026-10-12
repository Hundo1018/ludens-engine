"""AI decision seam (ROADMAP 17.15): cost per decision.

Table 1: the guard behaviour of `test_ai_decision` (patrol / chase / attack /
search / flee) built as a behavior tree, an FSM, a utility AI and a GOAP
planner; 10 000 agents with seeded random blackboards, one decision each per
tick, 10 ticks. Table 2: GOAP planning cost against the number of actions in
a chain domain (the plan has to use all of them in order) -- the planner's
scaling axis. Table 3: behavior tree tick cost against tree size (a reactive
selector over N guarded branches, only the last one applies). Table 4: the
spatial services -- boids step per boid (1e3 / 1e4 fish), perception
candidate generation (brute force over observer x target pairs), an EQS
grid query, influence propagation and team vision on a 128 x 128 grid.

Run: pixi run mojo run -I build benchmarks/bench_ai.mojo
"""

from std.benchmark import keep
from harness.bench import BenchTable, now
from geometry.vec import Real
from scheduler.rng import SplitMix64, Rng
from ai.blackboard import Blackboard, CMP_TRUE, CMP_FALSE, CMP_LT, CMP_GE
from ai.bt import BehaviorTree, BtState, BtHost, bt_tick, RUNNING
from ai.utility import UtilityAI, Consideration, CURVE_STEP, CURVE_STEP_BELOW
from ai.planner import Goap, Op
from ai.decision import Decider, BtDecider, FsmDecider, UtilityDecider, GoapDecider, Cond, Fact, Goal
from ai.steering import Flock, FlockParams
from ai.perception import Perception, SenseConfig
from ai.eqs import EnvQuery
from ai.influence import InfluenceMap, TeamVision
from geometry.vec import Vec3

comptime VIS = 0
comptime DIST = 1
comptime LOW = 2
comptime LKP = 3
comptime SEARCH_T = 4
comptime KEYS = 5
comptime PATROL = 0
comptime CHASE = 1
comptime ATTACK = 2
comptime SEARCH = 3
comptime FLEE = 4


def _c(key: Int, op: Int, v: Real = 0) -> Cond:
    return Cond(key, op, v)


def make_bt() raises -> BtDecider:
    var t = BehaviorTree()
    var root = t.selector(reactive=True)
    var s1 = t.sequence(reactive=True)
    t.add_child(root, s1)
    t.add_child(s1, t.condition(VIS, CMP_TRUE))
    t.add_child(s1, t.condition(LOW, CMP_TRUE))
    t.add_child(s1, t.action(FLEE))
    var s2 = t.sequence(reactive=True)
    t.add_child(root, s2)
    t.add_child(s2, t.condition(VIS, CMP_TRUE))
    t.add_child(s2, t.condition(DIST, CMP_LT, 2))
    t.add_child(s2, t.action(ATTACK))
    var s3 = t.sequence(reactive=True)
    t.add_child(root, s3)
    t.add_child(s3, t.condition(VIS, CMP_TRUE))
    t.add_child(s3, t.action(CHASE))
    var s4 = t.sequence(reactive=True)
    t.add_child(root, s4)
    t.add_child(s4, t.condition(LKP, CMP_TRUE))
    t.add_child(s4, t.condition(SEARCH_T, CMP_LT, 300))
    t.add_child(s4, t.action(SEARCH))
    t.add_child(root, t.action(PATROL))
    return BtDecider(t^)


def make_fsm() -> FsmDecider:
    var f = FsmDecider(0)
    var p = f.add_state(PATROL)
    var c = f.add_state(CHASE)
    var a = f.add_state(ATTACK)
    var s = f.add_state(SEARCH)
    var fl = f.add_state(FLEE)
    f.add_transition(-1, fl, [_c(VIS, CMP_TRUE), _c(LOW, CMP_TRUE)])
    f.add_transition(-1, a, [_c(VIS, CMP_TRUE), _c(LOW, CMP_FALSE), _c(DIST, CMP_LT, 2)])
    f.add_transition(-1, c, [_c(VIS, CMP_TRUE), _c(LOW, CMP_FALSE), _c(DIST, CMP_GE, 2)])
    f.add_transition(-1, s, [_c(VIS, CMP_FALSE), _c(LKP, CMP_TRUE), _c(SEARCH_T, CMP_LT, 300)])
    f.add_transition(-1, p, [_c(VIS, CMP_FALSE), _c(LKP, CMP_FALSE)])
    f.add_transition(-1, p, [_c(VIS, CMP_FALSE), _c(SEARCH_T, CMP_GE, 300)])
    return f^


def make_utility() -> UtilityDecider:
    var u = UtilityAI(momentum=0)
    _ = u.add_action(1)
    var chase = u.add_action(3)
    var attack = u.add_action(4)
    var search = u.add_action(2)
    var flee = u.add_action(5)
    u.consider(chase, Consideration(VIS, 0, 1, CURVE_STEP, 0, 0, 0, 0.5, 0))
    u.consider(attack, Consideration(VIS, 0, 1, CURVE_STEP, 0, 0, 0, 0.5, 0))
    u.consider(attack, Consideration(DIST, 0, 4, CURVE_STEP_BELOW, 0, 0, 0, 0.5, 0))
    u.consider(search, Consideration(LKP, 0, 1, CURVE_STEP, 0, 0, 0, 0.5, 0))
    u.consider(search, Consideration(SEARCH_T, 0, 600, CURVE_STEP_BELOW, 0, 0, 0, 0.5, 0))
    u.consider(flee, Consideration(VIS, 0, 1, CURVE_STEP, 0, 0, 0, 0.5, 0))
    u.consider(flee, Consideration(LOW, 0, 1, CURVE_STEP, 0, 0, 0, 0.5, 0))
    return UtilityDecider(u^)


def make_goap() raises -> GoapDecider:
    var g = GoapDecider(Goap())
    g.facts.append(Fact(0, _c(VIS, CMP_TRUE)))
    g.facts.append(Fact(1, _c(DIST, CMP_LT, 2)))
    g.facts.append(Fact(2, _c(LOW, CMP_TRUE)))
    g.facts.append(Fact(3, _c(LKP, CMP_TRUE)))
    g.facts.append(Fact(4, _c(SEARCH_T, CMP_LT, 300)))
    g.add_op(Op(0, 0, 32, 32, 1), FLEE)
    g.add_op(Op(3, 3, 64, 64, 1), ATTACK)
    g.add_op(Op(3, 1, 2, 2, 1), CHASE)
    g.add_op(Op(8, 8, 128, 128, 1), SEARCH)
    g.add_op(Op(0, 0, 256, 256, 1), PATROL)
    g.goals.append(Goal(5, 5, 32, 32))
    g.goals.append(Goal(1, 1, 64, 64))
    g.goals.append(Goal(25, 24, 128, 128))
    g.goals.append(Goal(0, 0, 256, 256))
    return g^


def _bbs(n: Int) -> List[Blackboard]:
    var rng = SplitMix64.seeded(1715)
    var out = List[Blackboard]()
    for _ in range(n):
        var bb = Blackboard(KEYS)
        bb.set_flag(VIS, rng.next_f32() < 0.5)
        bb.set(DIST, rng.next_f32() * 6)
        bb.set_flag(LOW, rng.next_f32() < 0.3)
        bb.set_flag(LKP, rng.next_f32() < 0.5)
        bb.set(SEARCH_T, rng.next_f32() * 600)
        out.append(bb^)
    return out^


def _run[D: Decider](mut t: BenchTable, var d: D, name: String, mut bbs: List[Blackboard]):
    var n = len(bbs)
    var acc = 0
    var t0 = now()
    for _ in range(10):
        for i in range(n):
            acc += d.decide(i, bbs[i])
    t.add(name, n, "decision", now() - t0, 10 * n)
    keep(acc)


struct _Rec(BtHost):
    var hits: Int

    def __init__(out self):
        self.hits = 0

    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        self.hits += 1
        return RUNNING

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        pass

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        return False

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        pass


def main() raises:
    var bbs = _bbs(10000)
    var t = BenchTable("Decision seam (17.15): guard behaviour, 10 000 agents x 10 ticks")
    _run(t, make_bt(), "BtDecider (reactive selector, 5 branches)", bbs)
    _run(t, make_fsm(), "FsmDecider (6 guarded transitions)", bbs)
    _run(t, make_utility(), "UtilityDecider (5 actions, 7 considerations)", bbs)
    _run(t, make_goap(), "GoapDecider (5 ops, 4 goals, plan per decision)", bbs)
    t.print_report()

    var tg = BenchTable("GOAP planning (17.15): chain domain, plan uses every action")
    for n in [4, 8, 16, 32]:
        var g = Goap(max_expand=100000)
        for k in range(n):
            var pre = UInt64(1) << UInt64(k) if k > 0 else UInt64(0)
            var bit = UInt64(1) << UInt64(k + 1)
            _ = g.add(Op(pre, pre, bit, bit, 1))
            # a distractor per step: same effect, dearer
            _ = g.add(Op(pre, pre, bit, bit, 3))
        var goal = UInt64(1) << UInt64(n)
        var reps = 50
        var plen = 0
        var t0 = now()
        for _ in range(reps):
            plen += len(g.plan(0, goal, goal))
        tg.add("Goap " + String(2 * n) + " actions (plan length " + String(plen // reps) + ", expanded " + String(g.last_expanded) + ")", 2 * n, "plan", now() - t0, reps)
    tg.print_report()

    var tb = BenchTable("Behavior tree tick (17.15): reactive selector over N guarded branches, last applies")
    for n in [4, 16, 64, 256]:
        var tree = BehaviorTree()
        var root = tree.selector(reactive=True)
        for k in range(n):
            var sq = tree.sequence(reactive=True)
            tree.add_child(root, sq)
            tree.add_child(sq, tree.condition(0, CMP_GE, Real(n - 1 - k)))
            tree.add_child(sq, tree.action(k))
        var st = BtState(tree)
        var bb = Blackboard(1)
        bb.set(0, 0)
        var h = _Rec()
        var reps = 20000
        var t0 = now()
        for _ in range(reps):
            _ = bt_tick(tree, st, h, 0, bb)
        tb.add("BT " + String(len(tree)) + " nodes", n, "tick", now() - t0, reps)
        keep(h.hits)
    tb.print_report()

    # spatial services
    var ts = BenchTable("AI spatial services (17.15)")
    for n in [1000, 10000]:
        var f = Flock(FlockParams(3.0, 1.5, 1.0, 1.0, 2.0, 4.0, 1.0, 1.0))
        var rng = SplitMix64.seeded(11)
        var side = Real(sqrt_int(n)) * 1.5
        for _ in range(n):
            _ = f.add(Vec3(rng.next_f32() * side, 0, rng.next_f32() * side, 0), Vec3(rng.next_f32() * 2 - 1, 0, rng.next_f32() * 2 - 1, 0))
        f.step(1.0 / 30.0)
        f.neighbour_checks = 0
        var t0 = now()
        for _ in range(30):
            f.step(1.0 / 30.0)
        ts.add("Flock step (" + String(f.neighbour_checks // (30 * n)) + " neighbour checks / boid)", n, "boid-step", now() - t0, 30 * n)
    var per = Perception()
    var rp = SplitMix64.seeded(12)
    for _ in range(1000):
        _ = per.add_observer(Vec3(rp.next_f32() * 200, 0, rp.next_f32() * 200, 0), Vec3(1, 0, 0, 0), 0, SenseConfig.default())
    for _ in range(1000):
        _ = per.add_target(Vec3(rp.next_f32() * 200, 0, rp.next_f32() * 200, 0), 1)
    var t1 = now()
    var cands = 0
    for _ in range(5):
        cands = per.sight_candidates()
    ts.add("Perception candidates 1000 x 1000 (" + String(cands) + " rays)", 1000000, "pair", now() - t1, 5 * 1000000)
    var t2 = now()
    var best = 0
    for _ in range(100):
        var q = EnvQuery()
        q.grid(Vec3(0, 0, 0, 0), 10, 1)
        q.distance_to(Vec3(3, 0, 4, 0))
        q.facing(Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), weight=0.5)
        best += q.run()[0]
    ts.add("EQS 21 x 21 grid, 2 tests", 441, "query", now() - t2, 100)
    keep(best)
    var im = InfluenceMap(Vec3(0, 0, 0, 0), 128, 128, 1.0, 2)
    for k in range(20):
        im.stamp(0, Vec3(Real(k * 6 + 3), 0, 30, 0), 1, 3)
    var t3 = now()
    im.propagate(0, 0.1, 0.9, 10)
    ts.add("Influence propagate 128 x 128", 16384, "cell-iteration", now() - t3, 16384 * 10)
    var vis = TeamVision(im, 1)
    var units = List[Vec3]()
    for k in range(50):
        units.append(Vec3(Real((k * 37) % 128), 0, Real((k * 53) % 128), 0))
    var t4 = now()
    vis.update(im, 0, units, 12)
    ts.add("Team vision 50 units, radius 12 (" + String(vis.los_checks) + " lines)", 50, "unit", now() - t4, 50)
    ts.print_report()


def sqrt_int(n: Int) -> Int:
    var r = 1
    while (r + 1) * (r + 1) <= n:
        r += 1
    return r
