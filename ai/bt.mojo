"""Behavior trees (ROADMAP 17.15).

A `BehaviorTree` is a shared, data-only definition (flat node arrays, built
with `add_*`); each agent owns a `BtState` (per-node running child, counters,
timers), so 10 000 agents share one tree. Leaves are executed by the host's
`BtHost` (comptime generic): actions return SUCCESS / FAILURE / RUNNING,
custom conditions return a Bool, services run on an interval.

Node kinds:
- composites: `SEQUENCE` / `SELECTOR` remember their running child between
  ticks; the `reactive` flag re-evaluates from the first child every tick, so
  a higher-priority branch preempts a running lower one (the lower one is
  aborted through `BtHost.abort`); `PARALLEL` ticks every unfinished child
  (a finished child keeps its status) and succeeds when `need` children
  succeeded, fails when that became impossible, aborting the rest;
- decorators: `INVERTER`, `SUCCEEDER`, `REPEAT(n)` (n <= 0: forever),
  `COOLDOWN(ticks)`, `GUARD(key, op, value, abort)` -- the child runs only
  while the blackboard condition holds; with `abort` it is re-checked every
  tick and a running child is aborted when it stops holding --, `SERVICE(id,
  interval)` -- runs the host service every `interval` ticks while the
  subtree is active;
- leaves: `ACTION(id)`, `CONDITION(key, op, value)` (blackboard),
  `CHECK(id)` (host condition), `WAIT(ticks)`.

Determinism: same tree, same blackboard writes, same host answers -> same
leaf sequence. The tick is iterative (explicit frame stack), so depth is not
limited by the call stack (`test_ai_bt` runs a 20 000-deep decorator chain;
the recursive first version overflowed the stack near 2000).
"""

from geometry.vec import Real
from ai.blackboard import Blackboard

comptime SUCCESS = 0
comptime FAILURE = 1
comptime RUNNING = 2

comptime BT_SEQUENCE = 0
comptime BT_SELECTOR = 1
comptime BT_PARALLEL = 2
comptime BT_INVERTER = 3
comptime BT_SUCCEEDER = 4
comptime BT_REPEAT = 5
comptime BT_COOLDOWN = 6
comptime BT_GUARD = 7
comptime BT_SERVICE = 8
comptime BT_ACTION = 9
comptime BT_CONDITION = 10
comptime BT_CHECK = 11
comptime BT_WAIT = 12


trait BtHost(Movable):
    def run(mut self, agent: Int, action: Int, mut bb: Blackboard) -> Int:
        """Execute leaf `action` for one tick: SUCCESS, FAILURE or RUNNING."""
        ...

    def abort(mut self, agent: Int, action: Int, mut bb: Blackboard):
        """A RUNNING action was preempted (reactive composite or guard)."""
        ...

    def check(mut self, agent: Int, cond: Int, bb: Blackboard) -> Bool:
        """Host-defined condition leaf."""
        ...

    def service(mut self, agent: Int, svc: Int, mut bb: Blackboard):
        """Periodic background update attached to a subtree."""
        ...


struct BehaviorTree(Movable, Sized):
    var kind: List[Int]
    var a: List[Int]  # action / key / count / ticks / service id / `need`
    var b: List[Int]  # comparison op / interval / reactive flag / guard: (op << 1) | abort
    var v: List[Real]  # comparison value
    var child_start: List[Int]
    var children: List[List[Int]]
    var root: Int

    def __init__(out self):
        self.kind = List[Int]()
        self.a = List[Int]()
        self.b = List[Int]()
        self.v = List[Real]()
        self.child_start = List[Int]()
        self.children = List[List[Int]]()
        self.root = -1

    def __len__(self) -> Int:
        return len(self.kind)

    def _node(mut self, kind: Int, a: Int = 0, b: Int = 0, v: Real = 0) -> Int:
        self.kind.append(kind)
        self.a.append(a)
        self.b.append(b)
        self.v.append(v)
        self.children.append(List[Int]())
        if self.root < 0:
            self.root = len(self.kind) - 1
        return len(self.kind) - 1

    def add_child(mut self, parent: Int, child: Int) raises:
        var k = self.kind[parent]
        if k >= BT_ACTION:
            raise Error("BehaviorTree.add_child: leaves have no children")
        if k >= BT_INVERTER and k <= BT_SERVICE and len(self.children[parent]) >= 1:
            raise Error("BehaviorTree.add_child: a decorator has exactly one child")
        if child == self.root:
            raise Error("BehaviorTree.add_child: the root cannot be a child")
        self.children[parent].append(child)

    def set_root(mut self, n: Int):
        self.root = n

    def sequence(mut self, reactive: Bool = False) -> Int:
        return self._node(BT_SEQUENCE, 0, 1 if reactive else 0)

    def selector(mut self, reactive: Bool = False) -> Int:
        return self._node(BT_SELECTOR, 0, 1 if reactive else 0)

    def parallel(mut self, need: Int) -> Int:
        """Succeeds once `need` children succeeded."""
        return self._node(BT_PARALLEL, need)

    def inverter(mut self) -> Int:
        return self._node(BT_INVERTER)

    def succeeder(mut self) -> Int:
        return self._node(BT_SUCCEEDER)

    def repeat(mut self, n: Int) -> Int:
        return self._node(BT_REPEAT, n)

    def cooldown(mut self, ticks: Int) -> Int:
        return self._node(BT_COOLDOWN, ticks)

    def guard(mut self, key: Int, op: Int, value: Real = 0, abort: Bool = True) -> Int:
        # b packs (op << 1) | abort
        return self._node(BT_GUARD, key, (op << 1) | (1 if abort else 0), value)

    def service(mut self, svc: Int, interval: Int) -> Int:
        return self._node(BT_SERVICE, svc, max(1, interval))

    def action(mut self, id: Int) -> Int:
        return self._node(BT_ACTION, id)

    def condition(mut self, key: Int, op: Int, value: Real = 0) -> Int:
        return self._node(BT_CONDITION, key, op, value)

    def check(mut self, id: Int) -> Int:
        return self._node(BT_CHECK, id)

    def wait(mut self, ticks: Int) -> Int:
        return self._node(BT_WAIT, ticks)

    def validate(self) raises:
        """Every composite has children, every decorator exactly one, no node
        has two parents, and the root reaches every node (a tree)."""
        if self.root < 0:
            raise Error("BehaviorTree: empty tree")
        var parents = List[Int](length=len(self.kind), fill=0)
        for n in range(len(self.kind)):
            var k = self.kind[n]
            var nc = len(self.children[n])
            if k <= BT_PARALLEL and nc == 0:
                raise Error("BehaviorTree: composite without children")
            if k >= BT_INVERTER and k <= BT_SERVICE and nc != 1:
                raise Error("BehaviorTree: decorator needs exactly one child")
            for c in self.children[n]:
                parents[c] += 1
        for n in range(len(self.kind)):
            if parents[n] > 1:
                raise Error("BehaviorTree: node with two parents")
            if n != self.root and parents[n] == 0:
                raise Error("BehaviorTree: node unreachable from the root")


struct BtState(Copyable, Movable):
    """Per-agent execution state for one tree."""

    var running: List[Int]  # composite: index of the running child, -1 = none
    var counter: List[Int]  # repeat: iterations done; wait: ticks waited
    var ready_at: List[Int]  # cooldown: tick the child may run again
    var last_service: List[Int]
    var active: List[Bool]  # node returned RUNNING last tick
    var finished: List[Int]  # child of a parallel: status once done, -1 = still to run
    var tick: Int
    var leaves_run: List[Int]  # actions ticked by the last `tick`, in order
    # frame-stack scratch for the iterative tick, kept to avoid per-tick allocation
    var _fnode: List[Int]
    var _fi: List[Int]
    var _fok: List[Int]
    var _ffail: List[Int]

    def __init__(out self, tree: BehaviorTree):
        var n = len(tree)
        self.running = List[Int](length=n, fill=-1)
        self.counter = List[Int](length=n, fill=0)
        self.ready_at = List[Int](length=n, fill=0)
        self.last_service = List[Int](length=n, fill=-1 << 30)
        self.active = List[Bool](length=n, fill=False)
        self.finished = List[Int](length=n, fill=-1)
        self.tick = 0
        self.leaves_run = List[Int]()
        self._fnode = List[Int]()
        self._fi = List[Int]()
        self._fok = List[Int]()
        self._ffail = List[Int]()


def bt_tick[H: BtHost](tree: BehaviorTree, mut st: BtState, mut host: H, agent: Int, mut bb: Blackboard) -> Int:
    """Tick the tree once from the root; returns the root's status.

    Iterative: an explicit frame stack (node, next child, parallel tallies)
    replaces recursion, so tree depth is bounded by memory, not the call
    stack. A frame with `i == -1` is being entered; otherwise `ret` holds the
    status of its child `i`, just finished."""
    st.leaves_run.clear()
    # frame stack (kept in `st` to avoid per-tick allocation): node, child
    # index (-1 = entering), parallel successes / failures so far this tick
    st._fnode.clear()
    st._fi.clear()
    st._fok.clear()
    st._ffail.clear()
    st._fnode.append(tree.root)
    st._fi.append(-1)
    st._fok.append(0)
    st._ffail.append(0)
    var ret = -1
    while len(st._fnode) > 0:
        var top = len(st._fnode) - 1
        var n = st._fnode[top]
        var k = tree.kind[n]
        var i = st._fi[top]
        var done = -1  # this frame's result when it finishes now
        var push = -1  # child to descend into
        if k >= BT_ACTION:
            match k:
                case == BT_ACTION:
                    st.leaves_run.append(tree.a[n])
                    done = host.run(agent, tree.a[n], bb)
                case == BT_CONDITION:
                    done = SUCCESS if bb.test(tree.a[n], tree.b[n], tree.v[n]) else FAILURE
                case == BT_CHECK:
                    done = SUCCESS if host.check(agent, tree.a[n], bb) else FAILURE
                case _:
                    st.counter[n] += 1
                    if st.counter[n] >= tree.a[n]:
                        st.counter[n] = 0
                        done = SUCCESS
                    else:
                        done = RUNNING
        elif k == BT_SEQUENCE or k == BT_SELECTOR:
            var stop_on = FAILURE if k == BT_SEQUENCE else SUCCESS
            var nc = len(tree.children[n])
            if i < 0:
                i = 0 if tree.b[n] != 0 or st.running[n] < 0 else st.running[n]
                push = i
            else:
                var prev = st.running[n]
                if ret == RUNNING or ret == stop_on:
                    # a reactive composite preempts the previously running child
                    if prev >= 0 and prev != i:
                        _abort(tree, st, host, agent, bb, tree.children[n][prev])
                    st.running[n] = i if ret == RUNNING else -1
                    done = ret
                else:
                    i += 1
                    push = i
            if push >= nc:
                push = -1
                st.running[n] = -1
                done = SUCCESS if k == BT_SEQUENCE else FAILURE
        elif k == BT_PARALLEL:
            var nc = len(tree.children[n])
            if i < 0:
                i = 0
            else:
                var c = tree.children[n][i]
                if ret != RUNNING:
                    st.finished[c] = ret
                if ret == SUCCESS:
                    st._fok[top] += 1
                elif ret == FAILURE:
                    st._ffail[top] += 1
                i += 1
            # skip children that already finished in an earlier tick
            while i < nc and st.finished[tree.children[n][i]] >= 0:
                if st.finished[tree.children[n][i]] == SUCCESS:
                    st._fok[top] += 1
                else:
                    st._ffail[top] += 1
                i += 1
            if i < nc:
                push = i
            else:
                var need = min(max(tree.a[n], 1), nc)
                if st._fok[top] >= need or nc - st._ffail[top] < need:
                    for c in tree.children[n]:
                        _abort(tree, st, host, agent, bb, c)
                        st.finished[c] = -1
                    done = SUCCESS if st._fok[top] >= need else FAILURE
                else:
                    done = RUNNING
        else:
            var child = tree.children[n][0]
            if i < 0:
                if k == BT_COOLDOWN and st.tick < st.ready_at[n] and not st.active[child]:
                    done = FAILURE
                elif k == BT_GUARD and not bb.test(tree.a[n], tree.b[n] >> 1, tree.v[n]):
                    if st.active[child] and (tree.b[n] & 1) != 0:
                        _abort(tree, st, host, agent, bb, child)
                        done = FAILURE
                    elif st.active[child]:
                        push = 0
                    else:
                        done = FAILURE
                else:
                    if k == BT_SERVICE and st.tick - st.last_service[n] >= tree.b[n]:
                        host.service(agent, tree.a[n], bb)
                        st.last_service[n] = st.tick
                    push = 0
            else:
                var r = ret
                match k:
                    case == BT_INVERTER:
                        done = r if r == RUNNING else (FAILURE if r == SUCCESS else SUCCESS)
                    case == BT_SUCCEEDER:
                        done = RUNNING if r == RUNNING else SUCCESS
                    case == BT_REPEAT:
                        match r:
                            case == RUNNING:
                                done = RUNNING
                            case == FAILURE:
                                st.counter[n] = 0
                                done = FAILURE
                            case _:
                                st.counter[n] += 1
                                if tree.a[n] > 0 and st.counter[n] >= tree.a[n]:
                                    st.counter[n] = 0
                                    done = SUCCESS
                                else:
                                    done = RUNNING
                    case == BT_COOLDOWN:
                        if r != RUNNING:
                            st.ready_at[n] = st.tick + tree.a[n]
                        done = r
                    case _:
                        done = r  # guard, service: pass through
        if push >= 0:
            st._fi[top] = push
            st._fnode.append(tree.children[n][push])
            st._fi.append(-1)
            st._fok.append(0)
            st._ffail.append(0)
            ret = -1
            continue
        st._fi[top] = i
        st.active[n] = done == RUNNING
        _ = st._fnode.pop()
        _ = st._fi.pop()
        _ = st._fok.pop()
        _ = st._ffail.pop()
        ret = done
    st.tick += 1
    return ret


def _abort[H: BtHost](tree: BehaviorTree, mut st: BtState, mut host: H, agent: Int, mut bb: Blackboard, n: Int):
    """Abort a subtree that was RUNNING (iterative): running actions get
    `host.abort`, composites forget their running child, waits / repeats
    reset, parallel children forget their finished status."""
    var stack = List[Int]()
    stack.append(n)
    while len(stack) > 0:
        var m = stack.pop()
        if not st.active[m]:
            continue
        st.active[m] = False
        if tree.kind[m] == BT_ACTION:
            host.abort(agent, tree.a[m], bb)
            continue
        st.running[m] = -1
        st.counter[m] = 0
        for c in tree.children[m]:
            st.finished[c] = -1
            stack.append(c)
