"""Planners: GOAP and HTN (ROADMAP 17.15).

World state is a 64-bit fact set (`UInt64`); a condition is (mask, value):
it holds when `state & mask == value`.

GOAP (Orkin, F.E.A.R.): actions have a precondition, an effect (bits in
`set_mask` become `set_value`) and a cost; `Goap.plan` runs A* forward from
the current state to any state satisfying the goal. Heuristic: goal bits
still wrong x (cheapest action cost / 64) -- one action can fix at most 64
bits, so it never overestimates and the plan is cheapest. Ties break on
insertion order, so plans are deterministic. A search budget (`max_expand`) bounds the cost; exhausting it
returns no plan.

HTN (total-order SHOP style): compound tasks have methods (precondition +
subtask list), tried in order; primitive tasks are GOAP-style operators.
`Htn.plan` decomposes depth-first with backtracking, simulating effects, up to
`max_depth` decompositions.
"""

from geometry.vec import Real


@fieldwise_init
struct Op(Copyable, ImplicitlyCopyable, Movable):
    var pre_mask: UInt64
    var pre_value: UInt64
    var set_mask: UInt64
    var set_value: UInt64
    var cost: Real

    def applicable(self, s: UInt64) -> Bool:
        return (s & self.pre_mask) == self.pre_value

    def apply(self, s: UInt64) -> UInt64:
        return (s & ~self.set_mask) | (self.set_value & self.set_mask)


def _popcount(x: UInt64) -> Int:
    var n = 0
    var v = x
    while v != 0:
        v &= v - 1
        n += 1
    return n


struct Goap(Movable):
    var ops: List[Op]
    var max_expand: Int
    var last_expanded: Int

    def __init__(out self, max_expand: Int = 4096):
        self.ops = List[Op]()
        self.max_expand = max_expand
        self.last_expanded = 0

    def add(mut self, op: Op) raises -> Int:
        if op.cost <= 0:
            raise Error("Goap.add: action cost must be > 0")
        self.ops.append(op)
        return len(self.ops) - 1

    def plan(mut self, start: UInt64, goal_mask: UInt64, goal_value: UInt64) -> List[Int]:
        """Cheapest action sequence reaching the goal; empty when the goal
        already holds; [-1] when no plan exists within the budget."""
        var out = List[Int]()
        if (start & goal_mask) == goal_value:
            return out^
        var min_cost = Real(1e30)
        for o in self.ops:
            min_cost = min(min_cost, o.cost)
        var hscale = min_cost / 64
        # open list as parallel arrays; linear scan for the minimum (plans are
        # short and the budget bounds the node count)
        var st = List[UInt64]()
        var g = List[Real]()
        var f = List[Real]()
        var parent = List[Int]()
        var via = List[Int]()
        var closed = List[Bool]()
        st.append(start)
        g.append(0)
        f.append(Real(_popcount((start & goal_mask) ^ goal_value)) * hscale)
        parent.append(-1)
        via.append(-1)
        closed.append(False)
        self.last_expanded = 0
        while self.last_expanded < self.max_expand:
            var best = -1
            for i in range(len(st)):
                if not closed[i] and (best < 0 or f[i] < f[best]):
                    best = i
            if best < 0:
                break
            closed[best] = True
            self.last_expanded += 1
            if (st[best] & goal_mask) == goal_value:
                var rev = List[Int]()
                var c = best
                while parent[c] >= 0:
                    rev.append(via[c])
                    c = parent[c]
                for k in range(len(rev)):
                    out.append(rev[len(rev) - 1 - k])
                return out^
            for a in range(len(self.ops)):
                if not self.ops[a].applicable(st[best]):
                    continue
                var ns = self.ops[a].apply(st[best])
                var ng = g[best] + self.ops[a].cost
                var found = -1
                for i in range(len(st)):
                    if st[i] == ns:
                        found = i
                        break
                if found >= 0:
                    if closed[found] or ng >= g[found]:
                        continue
                    g[found] = ng
                    f[found] = ng + Real(_popcount((ns & goal_mask) ^ goal_value)) * hscale
                    parent[found] = best
                    via[found] = a
                else:
                    st.append(ns)
                    g.append(ng)
                    f.append(ng + Real(_popcount((ns & goal_mask) ^ goal_value)) * hscale)
                    parent.append(best)
                    via.append(a)
                    closed.append(False)
        out.append(-1)
        return out^


comptime TASK_PRIMITIVE = 0
comptime TASK_COMPOUND = 1


struct Htn(Movable):
    """Tasks are ids; a primitive task maps to an `Op`; a compound task has
    methods (precondition mask / value + subtask list) tried in order."""

    var kind: List[Int]
    var op: List[Op]
    var methods: List[List[Int]]  # per compound task: method ids
    var m_mask: List[UInt64]
    var m_value: List[UInt64]
    var m_sub: List[List[Int]]
    var max_depth: Int
    var last_steps: Int

    def __init__(out self, max_depth: Int = 256):
        self.kind = List[Int]()
        self.op = List[Op]()
        self.methods = List[List[Int]]()
        self.m_mask = List[UInt64]()
        self.m_value = List[UInt64]()
        self.m_sub = List[List[Int]]()
        self.max_depth = max_depth
        self.last_steps = 0

    def primitive(mut self, op: Op) -> Int:
        self.kind.append(TASK_PRIMITIVE)
        self.op.append(op)
        self.methods.append(List[Int]())
        return len(self.kind) - 1

    def compound(mut self) -> Int:
        self.kind.append(TASK_COMPOUND)
        self.op.append(Op(0, 0, 0, 0, 1))
        self.methods.append(List[Int]())
        return len(self.kind) - 1

    def method(mut self, task: Int, pre_mask: UInt64, pre_value: UInt64, var subtasks: List[Int]) raises -> Int:
        if self.kind[task] != TASK_COMPOUND:
            raise Error("Htn.method: task is not compound")
        for t in subtasks:
            if t < 0 or t >= len(self.kind):
                raise Error("Htn.method: unknown subtask")
        self.m_mask.append(pre_mask)
        self.m_value.append(pre_value)
        self.m_sub.append(subtasks^)
        self.methods[task].append(len(self.m_mask) - 1)
        return len(self.m_mask) - 1

    def plan(mut self, start: UInt64, root: Int) -> List[Int]:
        """Primitive task sequence; [-1] when no decomposition works within
        `max_depth` steps."""
        self.last_steps = 0
        var out = List[Int]()
        var agenda = List[Int]()
        agenda.append(root)
        var ok = self._decompose(start, agenda, out)
        if not ok:
            out = List[Int]()
            out.append(-1)
        return out^

    def _decompose(mut self, s: UInt64, agenda: List[Int], mut out: List[Int]) -> Bool:
        if len(agenda) == 0:
            return True
        self.last_steps += 1
        if self.last_steps > self.max_depth:
            return False
        var t = agenda[0]
        var rest = List[Int]()
        for i in range(1, len(agenda)):
            rest.append(agenda[i])
        if self.kind[t] == TASK_PRIMITIVE:
            if not self.op[t].applicable(s):
                return False
            out.append(t)
            if self._decompose(self.op[t].apply(s), rest, out):
                return True
            _ = out.pop()
            return False
        var ms = self.methods[t].copy()
        for m in ms:
            if (s & self.m_mask[m]) != self.m_value[m]:
                continue
            var ag = self.m_sub[m].copy()
            for r in rest:
                ag.append(r)
            var mark = len(out)
            if self._decompose(s, ag, out):
                return True
            while len(out) > mark:
                _ = out.pop()
        return False
