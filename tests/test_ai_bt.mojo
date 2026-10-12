# tier: component
"""Behavior tree semantics (ROADMAP 17.15).

Ordinary: memory sequence resumes its running child; reactive selector
preempts a running lower-priority branch and aborts it through the host;
guard with abort stops a running child when its condition fails; parallel
success / failure thresholds; repeat; cooldown; wait; service interval.
Extreme: a 20 000-deep decorator chain, a tree with a single leaf, an empty
tree / decorator with two children / composite without children / shared
child all raise, 10 000 agents share one tree with separate state.
"""

from harness.runner import Suite
from geometry.vec import Real
from ai.blackboard import Blackboard, CMP_TRUE, CMP_LT
from ai.bt import (
    BehaviorTree,
    BtState,
    BtHost,
    bt_tick,
    SUCCESS,
    FAILURE,
    RUNNING,
)


struct Host(BtHost):
    """Action i runs for `dur[i]` ticks then returns `result[i]`."""

    var dur: List[Int]
    var result: List[Int]
    var left: List[Int]
    var aborted: List[Int]
    var service_calls: Int
    var check_value: Bool

    def __init__(out self, n: Int):
        self.dur = List[Int](length=n, fill=1)
        self.result = List[Int](length=n, fill=SUCCESS)
        self.left = List[Int](length=n, fill=-1)
        self.aborted = List[Int]()
        self.service_calls = 0
        self.check_value = True

    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        if self.left[action] < 0:
            self.left[action] = self.dur[action]
        self.left[action] -= 1
        if self.left[action] <= 0:
            self.left[action] = -1
            return self.result[action]
        return RUNNING

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        self.aborted.append(action)
        self.left[action] = -1

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        return self.check_value

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        self.service_calls += 1


def main() raises:
    var s = Suite("ai_bt")
    var bb = Blackboard(4)

    # ---- memory sequence: A (1 tick) then B (3 ticks) ----
    var t1 = BehaviorTree()
    var seq = t1.sequence()
    t1.add_child(seq, t1.action(0))
    t1.add_child(seq, t1.action(1))
    var h1 = Host(4)
    h1.dur[1] = 3
    var st1 = BtState(t1)
    var r = List[Int]()
    var runs = List[Int]()
    for _ in range(3):
        r.append(bt_tick(t1, st1, h1, 0, bb))
        runs.append(len(st1.leaves_run))
    s.check(r[0] == RUNNING and r[1] == RUNNING and r[2] == SUCCESS, "sequence: A then B (3 ticks) -> R R S")
    s.check(runs[0] == 2 and runs[1] == 1 and runs[2] == 1, "memory: A is not re-run while B is running")

    # ---- reactive selector preempts and aborts ----
    var t2 = BehaviorTree()
    var sel = t2.selector(reactive=True)
    var hi = t2.sequence(reactive=True)
    t2.add_child(sel, hi)
    t2.add_child(hi, t2.condition(0, CMP_TRUE))
    t2.add_child(hi, t2.action(0))
    t2.add_child(sel, t2.action(1))
    var h2 = Host(4)
    h2.dur[0] = 100
    h2.dur[1] = 100
    var st2 = BtState(t2)
    _ = bt_tick(t2, st2, h2, 0, bb)
    s.check(st2.leaves_run[0] == 1, "low-priority action runs while the condition is false")
    bb.set_flag(0, True)
    _ = bt_tick(t2, st2, h2, 0, bb)
    s.check(st2.leaves_run[0] == 0, "condition true: high-priority branch takes over")
    s.check(len(h2.aborted) == 1 and h2.aborted[0] == 1, "the preempted action was aborted")
    bb.set_flag(0, False)
    _ = bt_tick(t2, st2, h2, 0, bb)
    s.check(len(h2.aborted) == 2 and h2.aborted[1] == 0, "and back: the high branch is aborted")

    # ---- guard with abort ----
    var t3 = BehaviorTree()
    var g = t3.guard(1, CMP_LT, 5.0, abort=True)
    t3.add_child(g, t3.action(2))
    var h3 = Host(4)
    h3.dur[2] = 100
    var st3 = BtState(t3)
    bb.set(1, 1.0)
    s.eqi(bt_tick(t3, st3, h3, 0, bb), RUNNING, "guard holds: child runs")
    bb.set(1, 9.0)
    s.eqi(bt_tick(t3, st3, h3, 0, bb), FAILURE, "guard fails: running child aborted, FAILURE")
    s.check(len(h3.aborted) == 1 and h3.aborted[0] == 2, "guard abort reached the host")

    # ---- parallel: need 2 of 3 ----
    var t4 = BehaviorTree()
    var par = t4.parallel(2)
    t4.add_child(par, t4.action(0))
    t4.add_child(par, t4.action(1))
    t4.add_child(par, t4.action(2))
    var h4 = Host(4)
    h4.dur[0] = 2
    h4.dur[1] = 3
    h4.dur[2] = 50
    var st4 = BtState(t4)
    s.eqi(bt_tick(t4, st4, h4, 0, bb), RUNNING, "parallel: none done yet")
    s.eqi(bt_tick(t4, st4, h4, 0, bb), RUNNING, "parallel: one success")
    s.eqi(bt_tick(t4, st4, h4, 0, bb), SUCCESS, "parallel: two successes -> SUCCESS")
    s.check(len(h4.aborted) == 1 and h4.aborted[0] == 2, "the still-running child is aborted")
    var h4b = Host(4)
    h4b.result[0] = FAILURE
    h4b.result[1] = FAILURE
    h4b.dur[2] = 50
    var st4b = BtState(t4)
    s.eqi(bt_tick(t4, st4b, h4b, 0, bb), FAILURE, "parallel: two failures make 2 of 3 impossible")

    # ---- repeat, cooldown, wait, service ----
    var t5 = BehaviorTree()
    var rep = t5.repeat(3)
    t5.add_child(rep, t5.action(0))
    var h5 = Host(4)
    var st5 = BtState(t5)
    var ticks = 0
    while bt_tick(t5, st5, h5, 0, bb) == RUNNING and ticks < 10:
        ticks += 1
    s.eqi(ticks, 2, "repeat(3) of a 1-tick action: 2 RUNNING ticks then SUCCESS")

    var t6 = BehaviorTree()
    var cd = t6.cooldown(5)
    t6.add_child(cd, t6.action(0))
    var h6 = Host(4)
    var st6 = BtState(t6)
    var pattern = String("")
    for _ in range(12):
        pattern += "S" if bt_tick(t6, st6, h6, 0, bb) == SUCCESS else "F"
    s.check(pattern == "SFFFFSFFFFSF", "cooldown(5): one success every 5 ticks (" + pattern + ")")

    var t7 = BehaviorTree()
    var sv = t7.service(0, 4)
    var w = t7.wait(10)
    t7.add_child(sv, w)
    var h7 = Host(4)
    var st7 = BtState(t7)
    var waited = 0
    while bt_tick(t7, st7, h7, 0, bb) == RUNNING:
        waited += 1
    s.eqi(waited, 9, "wait(10): 9 RUNNING ticks then SUCCESS")
    s.eqi(h7.service_calls, 3, "service every 4 ticks over 10 ticks: 3 calls")

    # ---- extremes ----
    var deep = BehaviorTree()
    var top = deep.inverter()
    var cur = top
    for _ in range(19999):
        var nx = deep.inverter()
        deep.add_child(cur, nx)
        cur = nx
    deep.add_child(cur, deep.action(0))
    deep.validate()
    var hd = Host(4)
    var std = BtState(deep)
    s.eqi(bt_tick(deep, std, hd, 0, bb), SUCCESS, "20 000 inverters over SUCCESS = SUCCESS (even count)")

    var leaf = BehaviorTree()
    _ = leaf.check(0)
    var hl = Host(4)
    hl.check_value = False
    var stl = BtState(leaf)
    s.eqi(bt_tick(leaf, stl, hl, 0, bb), FAILURE, "single host-condition leaf")

    var raised = False
    try:
        BehaviorTree().validate()
    except:
        raised = True
    s.check(raised, "empty tree raises")
    raised = False
    try:
        var bad = BehaviorTree()
        var inv = bad.inverter()
        bad.add_child(inv, bad.action(0))
        bad.add_child(inv, bad.action(1))
    except:
        raised = True
    s.check(raised, "decorator with two children raises")
    raised = False
    try:
        var bad2 = BehaviorTree()
        _ = bad2.sequence()
        bad2.validate()
    except:
        raised = True
    s.check(raised, "composite without children raises")
    raised = False
    try:
        var bad3 = BehaviorTree()
        var r3 = bad3.selector()
        var a3 = bad3.sequence()
        var b3 = bad3.sequence()
        var leaf3 = bad3.action(0)
        bad3.add_child(r3, a3)
        bad3.add_child(r3, b3)
        bad3.add_child(a3, leaf3)
        bad3.add_child(b3, leaf3)
        bad3.validate()
    except:
        raised = True
    s.check(raised, "a node with two parents raises")

    # 10 000 agents, one tree, separate state
    var states = List[BtState]()
    for _ in range(10000):
        states.append(BtState(t1))
    var hm = Host(4)
    hm.dur[0] = 3
    var done = 0
    for i in range(10000):
        if i % 2 == 0:
            _ = bt_tick(t1, states[i], hm, i, bb)
    for i in range(10000):
        if states[i].tick == (1 if i % 2 == 0 else 0):
            done += 1
    s.eqi(done, 10000, "10 000 agents: per-agent tick counters independent")
    s.finish()
