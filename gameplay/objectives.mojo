"""Objectives driven by events (ROADMAP 17.72).

An objective counts events of one type (`ItemPickedUp`, an enemy kill, a
flag change - any integer event type) up to a target; it becomes active
when all its prerequisites are complete. `optional` objectives do not block
`all_required_done`. Progress is plain values, so it saves and replays.

Dispatch is the seam: `DISPATCH_LINEAR` scans every objective per event,
`DISPATCH_INDEXED` looks up the objectives listening to that event type
(an inverted index extended on `add`). Either way only the listeners'
activeness is snapshotted before the hits. Both complete the same objectives in
the same order (`test_flow`); the index pays off with many objectives and
few listeners per event type (`bench_flow`).

Prerequisite cycles are rejected at `add` (raise), not discovered as a
quest that never starts.
"""

comptime DISPATCH_LINEAR = 0
comptime DISPATCH_INDEXED = 1


@fieldwise_init
struct Objective(Copyable, ImplicitlyCopyable, Movable):
    var event_type: Int
    var target: Int
    var progress: Int
    var optional: Bool
    var done: Bool


struct ObjectiveLog(Copyable, Movable):
    var objs: List[Objective]
    var prereq: List[List[Int]]
    var mode: Int
    var index: List[List[Int]]  # event type -> objectives
    var completed: List[Int]  # in completion order

    def __init__(out self, mode: Int = DISPATCH_INDEXED):
        self.objs = List[Objective]()
        self.prereq = List[List[Int]]()
        self.mode = mode
        self.index = List[List[Int]]()
        self.completed = List[Int]()

    def add(mut self, event_type: Int, target: Int, prereqs: List[Int], optional: Bool = False) raises -> Int:
        if target < 1 or event_type < 0:
            raise Error("ObjectiveLog.add: target >= 1 and event type >= 0")
        var id = len(self.objs)
        for p in prereqs:
            if p < 0 or p >= id:
                raise Error("ObjectiveLog.add: prerequisite " + String(p) + " is not an earlier objective (cycles are refused)")
        self.objs.append(Objective(event_type, target, 0, optional, False))
        self.prereq.append(prereqs.copy())
        while len(self.index) <= event_type:
            self.index.append(List[Int]())
        self.index[event_type].append(id)
        return id

    def active(self, i: Int) -> Bool:
        if self.objs[i].done:
            return False
        for p in self.prereq[i]:
            if not self.objs[p].done:
                return False
        return True

    def _hit(mut self, i: Int, amount: Int):
        if not self.active(i):
            return
        self.objs[i].progress = min(self.objs[i].progress + amount, self.objs[i].target)
        if self.objs[i].progress >= self.objs[i].target:
            self.objs[i].done = True
            self.completed.append(i)

    def on_event(mut self, event_type: Int, amount: Int = 1):
        """Progress every active objective listening to `event_type`, in
        objective order (one event does not also start objectives it
        unlocks: their count begins with the next event)."""
        if event_type < 0:
            return
        # snapshot which listeners are active before any hit, so an
        # objective unlocked by this event starts counting with the next one
        var listeners = List[Int]()
        if self.mode == DISPATCH_LINEAR:
            for i in range(len(self.objs)):
                if self.objs[i].event_type == event_type:
                    listeners.append(i)
        elif event_type < len(self.index):
            listeners = self.index[event_type].copy()
        var act = List[Bool](capacity=len(listeners))
        for i in listeners:
            act.append(self.active(i))
        for k in range(len(listeners)):
            if act[k]:
                self._hit(listeners[k], amount)

    def all_required_done(self) -> Bool:
        for o in self.objs:
            if not o.optional and not o.done:
                return False
        return True
