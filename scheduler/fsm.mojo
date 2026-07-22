"""Hierarchical state machine (UML-statechart flavour), data-driven.

States form a tree (leaf or composite); transitions are (from, event, to)
triples. `fire(event)` searches from the current leaf UP through its ancestors
for a matching transition (event bubbling), then performs the LCA exit/enter
dance: exit up to the least-common-ancestor of {current, target}, enter down
into the target, and descend into the target's initial (or, with shallow
history, last-active) child. `is_in(s)` is true for the current leaf AND every
ancestor, so `is_in(grounded)` holds while in idle/walk/run.

Actions are observable without callbacks: every `fire` (and `start`) records
the states it exited and entered into `exited` / `entered`, which the caller
reads or drains. Same events from the same start -> same state path
(`test_fsm`), so it is safe inside the deterministic game loop.
"""


struct StateMachine(Movable, ImplicitlyDeletable):
    var parent: List[Int]  # parent state id, -1 = top level
    var initial: List[Int]  # composite: child entered by default (-1 = leaf)
    var history: List[Bool]  # composite: resume last-active child on entry
    var last_child: List[Int]  # remembered active child (shallow history)
    var t_from: List[Int]
    var t_event: List[Int]
    var t_to: List[Int]
    var current: Int  # active LEAF state (-1 before start)
    var entered: List[Int]  # states entered by the last fire/start (outer->inner)
    var exited: List[Int]  # states exited by the last fire (inner->outer)

    def __init__(out self):
        self.parent = List[Int]()
        self.initial = List[Int]()
        self.history = List[Bool]()
        self.last_child = List[Int]()
        self.t_from = List[Int]()
        self.t_event = List[Int]()
        self.t_to = List[Int]()
        self.current = -1
        self.entered = List[Int]()
        self.exited = List[Int]()

    def add_state(
        mut self, parent: Int = -1, initial: Int = -1, history: Bool = False
    ) -> Int:
        """Register a state under `parent` (-1 = top). A composite state names
        its default `initial` child (set later via set_initial if the child id
        isn't known yet)."""
        self.parent.append(parent)
        self.initial.append(initial)
        self.history.append(history)
        self.last_child.append(-1)
        return len(self.parent) - 1

    def set_initial(mut self, composite: Int, child: Int):
        self.initial[composite] = child

    def add_transition(mut self, frm: Int, event: Int, to: Int):
        self.t_from.append(frm)
        self.t_event.append(event)
        self.t_to.append(to)

    def _is_ancestor(self, a: Int, s: Int) -> Bool:
        """True if `a` is `s` or an ancestor of `s`."""
        var x = s
        while x >= 0:
            if x == a:
                return True
            x = self.parent[x]
        return False

    def _descend(mut self, start: Int):
        """From `start`, walk into initial/history children, entering each."""
        var s = start
        while self.initial[s] >= 0:
            var child = self.initial[s]
            if self.history[s] and self.last_child[s] >= 0:
                child = self.last_child[s]
            self.entered.append(child)
            s = child
        self.current = s

    def start(mut self, state: Int):
        """Enter `state` from nothing, descending into its initial children."""
        self.entered = List[Int]()
        self.exited = List[Int]()
        # enter state and its ancestors, outermost first
        var chain = List[Int]()
        var x = state
        while x >= 0:
            chain.append(x)
            x = self.parent[x]
        for i in range(len(chain) - 1, -1, -1):
            self.entered.append(chain[i])
        self._descend(state)

    def fire(mut self, event: Int) -> Bool:
        """Process one event; return whether a transition fired."""
        self.entered = List[Int]()
        self.exited = List[Int]()
        # bubble up from the current leaf looking for a matching transition
        var src = self.current
        while src >= 0:
            var to = -1
            for i in range(len(self.t_from)):
                if self.t_from[i] == src and self.t_event[i] == event:
                    to = self.t_to[i]
                    break
            if to >= 0:
                self._transition(src, to)
                return True
            src = self.parent[src]
        return False

    def _transition(mut self, src: Int, to: Int):
        # least common ancestor of the current leaf and the target
        var lca = -1
        var a = src
        while a >= 0:
            if self._is_ancestor(a, to):
                lca = a
                break
            a = self.parent[a]
        # exit from the current leaf up to (not including) lca, recording
        # history at each composite we leave
        var x = self.current
        while x != lca and x >= 0:
            self.exited.append(x)
            var p = self.parent[x]
            if p >= 0:
                self.last_child[p] = x
            x = p
        # enter from below lca down to the target (outermost first)
        var chain = List[Int]()
        var y = to
        while y != lca and y >= 0:
            chain.append(y)
            y = self.parent[y]
        for i in range(len(chain) - 1, -1, -1):
            self.entered.append(chain[i])
        self._descend(to)

    def is_in(self, state: Int) -> Bool:
        """True if `state` is the current leaf or one of its ancestors."""
        return self._is_ancestor(state, self.current)
