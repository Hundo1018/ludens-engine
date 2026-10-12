# tier: component
"""GOAP / HTN planners and utility curves (ROADMAP 17.15).

GOAP: cold -> get axe -> chop wood -> light fire (the roadmap's example), the
cheapest of two routes, a goal already satisfied (empty plan), an unreachable
goal and an exhausted search budget ([-1]), a zero-cost action rejected.
HTN: methods tried in order with backtracking into the second method when the
first one's primitive fails later; depth limit.
Utility: each curve at known points; momentum keeps the running action.
"""

from harness.runner import Suite
from geometry.vec import Real
from ai.blackboard import Blackboard
from ai.planner import Goap, Htn, Op
from ai.utility import UtilityAI, Consideration, CURVE_LINEAR, CURVE_POLY, CURVE_LOGISTIC, CURVE_STEP, CURVE_STEP_BELOW

comptime COLD: UInt64 = 1
comptime HAS_AXE: UInt64 = 2
comptime HAS_WOOD: UInt64 = 4
comptime FIRE: UInt64 = 8
comptime HAS_MONEY: UInt64 = 16


def _eq(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var s = Suite("ai_planner")
    var g = Goap()
    var get_axe = g.add(Op(0, 0, HAS_AXE, HAS_AXE, 2))
    var chop = g.add(Op(HAS_AXE, HAS_AXE, HAS_WOOD, HAS_WOOD, 4))
    var buy = g.add(Op(HAS_MONEY, HAS_MONEY, HAS_WOOD | HAS_MONEY, HAS_WOOD, 1))
    var light = g.add(Op(HAS_WOOD, HAS_WOOD, FIRE | HAS_WOOD | COLD, FIRE, 1))
    var p = g.plan(COLD, FIRE, FIRE)
    s.check(_eq(p, [get_axe, chop, light]), "cold -> axe -> chop -> fire")
    var p2 = g.plan(COLD | HAS_MONEY, FIRE, FIRE)
    s.check(_eq(p2, [buy, light]), "with money: buying wood is cheaper (2 < 7)")
    s.eqi(len(g.plan(FIRE, FIRE, FIRE)), 0, "goal already holds: empty plan")
    var p3 = g.plan(COLD, HAS_MONEY, HAS_MONEY)
    s.check(len(p3) == 1 and p3[0] == -1, "no action yields money: [-1]")
    var tiny = Goap(max_expand=2)
    _ = tiny.add(Op(0, 0, HAS_AXE, HAS_AXE, 2))
    _ = tiny.add(Op(HAS_AXE, HAS_AXE, HAS_WOOD, HAS_WOOD, 4))
    _ = tiny.add(Op(HAS_WOOD, HAS_WOOD, FIRE, FIRE, 1))
    var p4 = tiny.plan(0, FIRE, FIRE)
    s.check(len(p4) == 1 and p4[0] == -1, "budget of 2 expansions: [-1]")
    var raised = False
    try:
        _ = g.add(Op(0, 0, 1, 1, 0))
    except:
        raised = True
    s.check(raised, "zero-cost action raises")

    # HTN: make_fire -> (method 1: chop route) | (method 2: buy route)
    var h = Htn()
    var t_axe = h.primitive(Op(0, 0, HAS_AXE, HAS_AXE, 1))
    var t_chop = h.primitive(Op(HAS_AXE | COLD, HAS_AXE | COLD, HAS_WOOD, HAS_WOOD, 1))  # needs COLD (contrived)
    var t_buy = h.primitive(Op(HAS_MONEY, HAS_MONEY, HAS_WOOD | HAS_MONEY, HAS_WOOD, 1))
    var t_light = h.primitive(Op(HAS_WOOD, HAS_WOOD, FIRE, FIRE, 1))
    var make_fire = h.compound()
    _ = h.method(make_fire, 0, 0, [t_axe, t_chop, t_light])
    _ = h.method(make_fire, HAS_MONEY, HAS_MONEY, [t_buy, t_light])
    s.check(_eq(h.plan(COLD, make_fire), [t_axe, t_chop, t_light]), "HTN: first method")
    s.check(_eq(h.plan(HAS_MONEY, make_fire), [t_buy, t_light]), "HTN: backtracks into the second method")
    var none = h.plan(0, make_fire)
    s.check(len(none) == 1 and none[0] == -1, "HTN: no method applies -> [-1]")
    var loop = h.compound()
    _ = h.method(loop, 0, 0, [loop])
    var pl = h.plan(0, loop)
    s.check(len(pl) == 1 and pl[0] == -1 and h.last_steps > h.max_depth, "HTN: infinite decomposition stops at max_depth")

    # utility curves
    var bb = Blackboard(2)
    bb.set(0, 0.25)
    s.almost(Float64(Consideration(0, 0, 1, CURVE_LINEAR, 2, 0, 0.1, 0, 0).score(bb)), 0.6, "linear 2x + 0.1 at 0.25")
    s.almost(Float64(Consideration(0, 0, 1, CURVE_POLY, 1, 2, 0, 0, 0).score(bb)), 0.0625, "x^2 at 0.25")
    s.almost(Float64(Consideration(0, 0, 1, CURVE_LOGISTIC, 10, 1, 0, 0.25, 0).score(bb)), 0.5, "logistic midpoint")
    s.almost(Float64(Consideration(0, 0, 1, CURVE_STEP, 0, 0, 0, 0.3, 0).score(bb)), 0.0, "step below threshold")
    s.almost(Float64(Consideration(0, 0, 1, CURVE_STEP_BELOW, 0, 0, 0, 0.3, 0).score(bb)), 1.0, "step-below")
    s.almost(Float64(Consideration(1, 0, 1, CURVE_LINEAR, 1, 0, 0, 0, 0.7).score(bb)), 0.7, "unset key scores `missing`")
    var u = UtilityAI(momentum=0.2)
    var a = u.add_action(1)
    var b = u.add_action(1)
    u.consider(a, Consideration(0, 0, 1, CURVE_LINEAR, 1, 0, 0, 0, 0))
    u.consider(b, Consideration(0, 0, 1, CURVE_LINEAR, -1, 0, 1, 0, 0))
    bb.set(0, 0.4)
    s.eqi(u.decide(0, bb), b, "x = 0.4: b (0.6) beats a (0.4)")
    bb.set(0, 0.55)
    s.eqi(u.decide(0, bb), b, "x = 0.55: momentum keeps b (0.45 + 0.2 > 0.55)")
    bb.set(0, 0.7)
    s.eqi(u.decide(0, bb), a, "x = 0.7: a wins despite momentum")
    s.finish()
