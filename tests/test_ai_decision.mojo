# tier: integration
"""Decision seam parity (ROADMAP 17.15): BT / FSM / utility / GOAP.

One guard behaviour, written four ways:
    flee    if the enemy is visible and health is low
    attack  if the enemy is visible and closer than 2 m
    chase   if the enemy is visible
    search  if there is a last known position and the search is < 300 ticks old
    patrol  otherwise
Laws: over a scripted 600-tick encounter (patrol -> spot -> chase -> attack ->
lose sight -> search -> give up -> patrol -> spot while hurt -> flee) and over
2000 seeded random blackboards, all four deciders return the action the rule
list above gives, tick for tick. A squad of three agents sharing one
blackboard decides identically, and per-agent state stays separate.
"""

from harness.runner import Suite
from geometry.vec import Real
from scheduler.rng import SplitMix64, Rng
from ai.blackboard import Blackboard, CMP_TRUE, CMP_FALSE, CMP_LT, CMP_GE
from ai.bt import BehaviorTree
from ai.utility import UtilityAI, Consideration, CURVE_STEP, CURVE_STEP_BELOW
from ai.planner import Goap, Op
from ai.decision import Decider, BtDecider, FsmDecider, UtilityDecider, GoapDecider, Cond, Fact, Goal

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


def truth(bb: Blackboard) -> Int:
    var vis = bb.flag(VIS)
    if vis and bb.flag(LOW):
        return FLEE
    if vis and bb.get(DIST) < 2:
        return ATTACK
    if vis:
        return CHASE
    if bb.flag(LKP) and bb.get(SEARCH_T) < 300:
        return SEARCH
    return PATROL


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


def _c(key: Int, op: Int, v: Real = 0) -> Cond:
    return Cond(key, op, v)


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


def _step(key: Int, c: Real, lo: Real = 0, hi: Real = 1) -> Consideration:
    return Consideration(key, lo, hi, CURVE_STEP, 0, 0, 0, c, 0)


def _below(key: Int, c: Real, lo: Real, hi: Real) -> Consideration:
    return Consideration(key, lo, hi, CURVE_STEP_BELOW, 0, 0, 0, c, 0)


def make_utility() -> UtilityDecider:
    var u = UtilityAI(momentum=0)
    var patrol = u.add_action(1)
    var chase = u.add_action(3)
    var attack = u.add_action(4)
    var search = u.add_action(2)
    var flee = u.add_action(5)
    _ = patrol
    u.consider(chase, _step(VIS, 0.5))
    u.consider(attack, _step(VIS, 0.5))
    u.consider(attack, _below(DIST, 0.5, 0, 4))  # dist / 4 < 0.5  <=>  dist < 2
    u.consider(search, _step(LKP, 0.5))
    u.consider(search, _below(SEARCH_T, 0.5, 0, 600))
    u.consider(flee, _step(VIS, 0.5))
    u.consider(flee, _step(LOW, 0.5))
    return UtilityDecider(u^)


def make_goap() raises -> GoapDecider:
    comptime B_VIS: UInt64 = 1
    comptime B_CLOSE: UInt64 = 2
    comptime B_LOW: UInt64 = 4
    comptime B_LKP: UInt64 = 8
    comptime B_FRESH: UInt64 = 16
    comptime B_SAFE: UInt64 = 32
    comptime B_DOWN: UInt64 = 64
    comptime B_FOUND: UInt64 = 128
    comptime B_PATROLLED: UInt64 = 256
    var g = GoapDecider(Goap())
    g.facts.append(Fact(0, _c(VIS, CMP_TRUE)))
    g.facts.append(Fact(1, _c(DIST, CMP_LT, 2)))
    g.facts.append(Fact(2, _c(LOW, CMP_TRUE)))
    g.facts.append(Fact(3, _c(LKP, CMP_TRUE)))
    g.facts.append(Fact(4, _c(SEARCH_T, CMP_LT, 300)))
    g.add_op(Op(0, 0, B_SAFE, B_SAFE, 1), FLEE)
    g.add_op(Op(B_VIS | B_CLOSE, B_VIS | B_CLOSE, B_DOWN, B_DOWN, 1), ATTACK)
    g.add_op(Op(B_VIS | B_CLOSE, B_VIS, B_CLOSE, B_CLOSE, 1), CHASE)
    g.add_op(Op(B_LKP, B_LKP, B_FOUND, B_FOUND, 1), SEARCH)
    g.add_op(Op(0, 0, B_PATROLLED, B_PATROLLED, 1), PATROL)
    g.goals.append(Goal(B_VIS | B_LOW, B_VIS | B_LOW, B_SAFE, B_SAFE))
    g.goals.append(Goal(B_VIS, B_VIS, B_DOWN, B_DOWN))
    g.goals.append(Goal(B_VIS | B_LKP | B_FRESH, B_LKP | B_FRESH, B_FOUND, B_FOUND))
    g.goals.append(Goal(0, 0, B_PATROLLED, B_PATROLLED))
    return g^


def _agree[D: Decider](mut d: D, script: List[Blackboard], agent: Int) -> Int:
    var ok = 0
    for i in range(len(script)):
        var bb = script[i].copy()
        if d.decide(agent, bb) == truth(script[i]):
            ok += 1
    return ok


def scripted() -> List[Blackboard]:
    """The 600-tick encounter: inputs only, independent of the decisions."""
    var out = List[Blackboard]()
    var bb = Blackboard(KEYS)
    bb.set_flag(VIS, False)
    bb.set(DIST, 50)
    bb.set_flag(LOW, False)
    bb.set_flag(LKP, False)
    bb.set(SEARCH_T, 0)
    for t in range(600):
        if t == 60:
            bb.set_flag(VIS, True)
            bb.set(DIST, 12)
        if t > 60 and t < 160 and bb.flag(VIS):
            bb.set(DIST, max(Real(0.5), bb.get(DIST) - 0.15))
        if t == 160:
            bb.set_flag(VIS, False)
            bb.set_flag(LKP, True)
            bb.set(SEARCH_T, 0)
        if t > 160 and bb.flag(LKP) and not bb.flag(VIS):
            bb.set(SEARCH_T, bb.get(SEARCH_T) + 1)
        if t == 470:
            bb.set_flag(LKP, False)
        if t == 520:
            bb.set_flag(LOW, True)
            bb.set_flag(VIS, True)
            bb.set(DIST, 1.5)
        out.append(bb.copy())
    return out^


def main() raises:
    var s = Suite("ai_decision")
    var script = scripted()
    var seen = List[Bool](length=5, fill=False)
    for b in script:
        seen[truth(b)] = True
    var all_seen = True
    for v in seen:
        all_seen = all_seen and v
    s.check(all_seen, "the script visits all five behaviours")

    var bt = make_bt()
    var fsm = make_fsm()
    var ut = make_utility()
    var gp = make_goap()
    s.eqi(_agree(bt, script, 0), 600, "BT follows the rules on the 600-tick script")
    s.eqi(_agree(fsm, script, 0), 600, "FSM follows the rules on the 600-tick script")
    s.eqi(_agree(ut, script, 0), 600, "utility follows the rules on the 600-tick script")
    s.eqi(_agree(gp, script, 0), 600, "GOAP follows the rules on the 600-tick script")

    # seeded random blackboards (any order: each decider keeps per-agent state)
    var rng = SplitMix64.seeded(1715)
    var rnd = List[Blackboard]()
    for _ in range(2000):
        var bb = Blackboard(KEYS)
        bb.set_flag(VIS, rng.next_f32() < 0.5)
        bb.set(DIST, rng.next_f32() * 6)
        bb.set_flag(LOW, rng.next_f32() < 0.3)
        bb.set_flag(LKP, rng.next_f32() < 0.5)
        bb.set(SEARCH_T, rng.next_f32() * 600)
        rnd.append(bb^)
    s.eqi(_agree(bt, rnd, 1), 2000, "BT on 2000 random blackboards")
    s.eqi(_agree(fsm, rnd, 1), 2000, "FSM on 2000 random blackboards")
    s.eqi(_agree(ut, rnd, 1), 2000, "utility on 2000 random blackboards")
    s.eqi(_agree(gp, rnd, 1), 2000, "GOAP on 2000 random blackboards")

    # squad: three agents share one blackboard
    var shared = script[200].copy()
    var a0 = bt.decide(10, shared)
    var a1 = bt.decide(11, shared)
    var a2 = bt.decide(12, shared)
    s.check(a0 == SEARCH and a1 == SEARCH and a2 == SEARCH, "squad sharing a blackboard all search")
    s.check(len(bt.states) == 13, "per-agent BT state allocated on demand")
    var f0 = fsm.decide(20, shared)
    s.check(f0 == SEARCH and fsm.machines[20] == 3, "FSM per-agent state is the search state")
    s.finish()
