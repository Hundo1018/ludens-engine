"""Decision-making seam (ROADMAP 17.15): `Decider`.

Four ways to turn an agent's blackboard into the action it should run now:

- `BtDecider`: a behavior tree; the decision is the first action leaf the
  tick reaches (every action reports RUNNING, so the tree re-decides each
  tick; preemption follows the tree's reactive composites);
- `FsmDecider`: a flat state machine (`procedural.fsm.StateMachine`) whose
  transitions are guarded by blackboard conditions; each tick the first
  matching transition out of the current state (or out of "any state") fires,
  repeatedly until none matches, and the state's action is the decision;
- `UtilityDecider`: `ai.utility.UtilityAI`'s best-scoring action;
- `GoapDecider`: goals in priority order, each with a relevance condition;
  the first relevant, unsatisfied goal is planned with `ai.planner.Goap` from
  the facts read off the blackboard; the decision is the plan's first step.

`test_ai_decision` builds the same guard behaviour (patrol / chase / attack /
search / flee) in all four and asserts the action sequences are identical over
a scripted 600-tick run and over seeded random inputs; `bench_ai` reports the
per-decision cost of each.
"""

from geometry.vec import Real
from procedural.fsm import StateMachine
from ai.blackboard import Blackboard
from ai.bt import BehaviorTree, BtState, BtHost, bt_tick, RUNNING
from ai.utility import UtilityAI
from ai.planner import Goap, Op


trait Decider(Movable, Deinitable):
    def decide(mut self, agent: Int, mut bb: Blackboard) -> Int:
        """Action to run now, or -1 for none."""
        ...


struct _Recorder(BtHost):
    """BT host that only records which action the tree selected."""

    var chosen: Int

    def __init__(out self):
        self.chosen = -1

    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        if self.chosen < 0:
            self.chosen = action
        return RUNNING

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        pass

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        return False

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        pass


struct BtDecider(Decider):
    var tree: BehaviorTree
    var states: List[BtState]
    var host: _Recorder

    def __init__(out self, var tree: BehaviorTree) raises:
        tree.validate()
        self.tree = tree^
        self.states = List[BtState]()
        self.host = _Recorder()

    def decide(mut self, agent: Int, mut bb: Blackboard) -> Int:
        while len(self.states) <= agent:
            self.states.append(BtState(self.tree))
        self.host.chosen = -1
        _ = bt_tick(self.tree, self.states[agent], self.host, agent, bb)
        return self.host.chosen


@fieldwise_init
struct Cond(Copyable, ImplicitlyCopyable, Movable):
    var key: Int
    var op: Int
    var value: Real


struct FsmDecider(Decider):
    var proto: StateMachine
    var machines: List[Int]  # per agent: current state (the machine is shared)
    var action_of: List[Int]
    var t_from: List[Int]  # -1 = any state
    var t_to: List[Int]
    var t_conds: List[List[Cond]]
    var initial: Int
    var max_chain: Int

    def __init__(out self, initial: Int):
        self.proto = StateMachine()
        self.machines = List[Int]()
        self.action_of = List[Int]()
        self.t_from = List[Int]()
        self.t_to = List[Int]()
        self.t_conds = List[List[Cond]]()
        self.initial = initial
        self.max_chain = 8

    def add_state(mut self, action: Int) -> Int:
        self.action_of.append(action)
        return self.proto.add_state()

    def add_transition(mut self, frm: Int, to: Int, var conds: List[Cond]):
        """Event id = transition index; registered on the shared machine for
        `frm` (or every state when frm == -1)."""
        var ev = len(self.t_from)
        self.t_from.append(frm)
        self.t_to.append(to)
        self.t_conds.append(conds^)
        if frm >= 0:
            self.proto.add_transition(frm, ev, to)
        else:
            for s in range(len(self.action_of)):
                if s != to:
                    self.proto.add_transition(s, ev, to)

    def _holds(self, t: Int, bb: Blackboard) -> Bool:
        for c in self.t_conds[t]:
            if not bb.test(c.key, c.op, c.value):
                return False
        return True

    def decide(mut self, agent: Int, mut bb: Blackboard) -> Int:
        while len(self.machines) <= agent:
            self.machines.append(self.initial)
        self.proto.start(self.machines[agent])
        for _ in range(self.max_chain):
            var fired = False
            for t in range(len(self.t_from)):
                var f = self.t_from[t]
                if (f == self.proto.current or f < 0) and self.t_to[t] != self.proto.current and self._holds(t, bb):
                    fired = self.proto.fire(t)
                    if fired:
                        break
            if not fired:
                break
        self.machines[agent] = self.proto.current
        return self.action_of[self.proto.current]


struct UtilityDecider(Decider):
    var ai: UtilityAI

    def __init__(out self, var ai: UtilityAI):
        self.ai = ai^

    def decide(mut self, agent: Int, mut bb: Blackboard) -> Int:
        return self.ai.decide(agent, bb)


@fieldwise_init
struct Fact(Copyable, ImplicitlyCopyable, Movable):
    var bit: Int
    var cond: Cond


@fieldwise_init
struct Goal(Copyable, ImplicitlyCopyable, Movable):
    var rel_mask: UInt64  # relevant when facts & rel_mask == rel_value
    var rel_value: UInt64
    var mask: UInt64  # satisfied when facts & mask == value
    var value: UInt64


struct GoapDecider(Decider):
    var goap: Goap
    var facts: List[Fact]
    var goals: List[Goal]
    var action_of_op: List[Int]
    var last_plan: List[Int]

    def __init__(out self, var goap: Goap):
        self.goap = goap^
        self.facts = List[Fact]()
        self.goals = List[Goal]()
        self.action_of_op = List[Int]()
        self.last_plan = List[Int]()

    def add_op(mut self, op: Op, action: Int) raises:
        _ = self.goap.add(op)
        self.action_of_op.append(action)

    def state(self, bb: Blackboard) -> UInt64:
        var s = UInt64(0)
        for f in self.facts:
            if bb.test(f.cond.key, f.cond.op, f.cond.value):
                s |= UInt64(1) << UInt64(f.bit)
        return s

    def decide(mut self, agent: Int, mut bb: Blackboard) -> Int:
        var s = self.state(bb)
        for g in self.goals:
            if (s & g.rel_mask) != g.rel_value or (s & g.mask) == g.value:
                continue
            var p = self.goap.plan(s, g.mask, g.value)
            if len(p) > 0 and p[0] >= 0:
                self.last_plan = p^
                return self.action_of_op[self.last_plan[0]]
        self.last_plan = List[Int]()
        return -1
