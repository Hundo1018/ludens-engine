"""The editor's state: the world being edited and its undo history (ludens-engine #6, #10).

Undo and redo are the engine's transaction layer (`embed.undo.UndoLog`, ludens-core 17.43): a command opens a
transaction, tells the editor which bodies it is about to change, changes them, and commits; the log keeps each
body's record from before and after, so one mechanism covers every kind of edit. Commands do not touch the log
directly; they use `begin`, `touch`, `created` and `commit` here, and `Registry.run` aborts an open transaction when
a command fails, so a failed command leaves the world and the history as they were."""
from editor.curve import CurveStep
from editor.graph import Graph, GraphHistory
from embed.undo import UndoLog
from embed.world import EmbedWorld
from geometry.vec import Vec3


struct Editor(Movable):
    var world: EmbedWorld
    var log: UndoLog
    var playing: Bool
    var play_blob: List[UInt8]  # the world as it was when play started
    var selection: List[Int64]  # selected body handles, in selection order
    var messages: List[String]  # errors and notices for the log panel, oldest first
    var curve: List[Vec3]  # the curve being edited (#19)
    var curve_past: List[CurveStep]
    var curve_future: List[CurveStep]
    var graph: Graph  # the node graph being edited (#20)
    var graph_hist: GraphHistory
    var order: List[Int]  # kind of each undo step, oldest first: 0 = world (UndoLog), 1 = curve, 2 = graph
    var redo_order: List[Int]
    var steps_at_begin: Int

    def __init__(out self, var world: EmbedWorld):
        self.world = world^
        self.log = UndoLog()
        self.playing = False
        self.play_blob = List[UInt8]()
        self.selection = List[Int64]()
        self.messages = List[String]()
        self.curve = List[Vec3]()
        self.curve_past = List[CurveStep]()
        self.curve_future = List[CurveStep]()
        self.graph = Graph(String("graph"))
        self.graph_hist = GraphHistory()
        self.order = List[Int]()
        self.redo_order = List[Int]()
        self.steps_at_begin = 0

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.log = move.log^
        self.playing = move.playing
        self.play_blob = move.play_blob^
        self.selection = move.selection^
        self.messages = move.messages^
        self.curve = move.curve^
        self.curve_past = move.curve_past^
        self.curve_future = move.curve_future^
        self.graph = move.graph^
        self.graph_hist = move.graph_hist^
        self.order = move.order^
        self.redo_order = move.redo_order^
        self.steps_at_begin = move.steps_at_begin

    # ---- play in editor: run the world, then put it back exactly as it was

    def play_begin(mut self) raises:
        """Keep a snapshot and let the world run. Edits are refused while playing (they would be lost on stop)."""
        if self.playing:
            raise Error("play: already playing")
        if self.log.depth > 0:
            raise Error("play: a transaction is open")
        self.play_blob = self.world.save()
        self.playing = True

    def play_ticks(mut self, n: Int) raises:
        if not self.playing:
            raise Error("play: not playing")
        for _ in range(n):
            for _ in range(self.world.ticks_due(1.0 / 60.0)):
                self.world.physics_tick()

    def play_stop(mut self) raises:
        """Restore the snapshot taken by `play_begin`; the world hash is the one it had before play."""
        if not self.playing:
            raise Error("play: not playing")
        self.world.load(self.play_blob)
        self.play_blob = List[UInt8]()
        self.playing = False

    # ---- selection

    def select(mut self, h: Int64, additive: Bool = False) raises:
        """Select body `h` (alone, or added to the selection)."""
        if not self.world.is_alive(h):
            raise Error("select: the handle is not a live body")
        if not additive:
            self.selection = List[Int64]()
        for s in self.selection:
            if s == h:
                return
        self.selection.append(h)

    def clear_selection(mut self):
        self.selection = List[Int64]()

    def prune_selection(mut self):
        """Drop handles whose bodies are gone (after a delete or an undo of an add)."""
        var kept = List[Int64]()
        for s in self.selection:
            if self.world.is_alive(s):
                kept.append(s)
        self.selection = kept^

    def is_selected(self, h: Int64) -> Bool:
        for s in self.selection:
            if s == h:
                return True
        return False

    def begin(mut self, name: String, merge_key: Int = 0) raises:
        if self.playing:
            raise Error("edit refused while playing; stop first")
        if self.log.depth == 0:
            self.steps_at_begin = self.log.steps()
        self.log.begin(name, merge_key)

    def touch(mut self, h: Int64) raises:
        """Call before changing body `h` inside a transaction."""
        self.log.touch(self.world, h)

    def created(mut self, h: Int64) raises:
        """Call right after adding body `h` inside a transaction."""
        self.log.created(self.world, h)

    def commit(mut self) raises:
        self.log.commit(self.world)
        if self.log.depth == 0 and self.log.steps() > self.steps_at_begin:
            self._new_step(0)  # a merged or empty transaction leaves the count as it was and adds no step

    def abort(mut self) raises:
        if self.log.depth > 0:
            self.log.abort(self.world)

    def _new_step(mut self, kind: Int):
        self.order.append(kind)
        self.redo_order = List[Int]()
        self.curve_future = List[CurveStep]()
        if kind != 2:
            self.graph_hist.future = List[String]()
            self.graph_hist.last_key = String()  # a drag does not merge across an unrelated step

    def reset_history(mut self):
        """Forget every undo and redo step (a reload replaced the world; the steps name bodies of the old one)."""
        self.log = UndoLog()
        self.curve_past = List[CurveStep]()
        self.curve_future = List[CurveStep]()
        self.graph_hist = GraphHistory()
        self.order = List[Int]()
        self.redo_order = List[Int]()

    # ---- the curve (#19): every edit is one step in the same history as the world's

    def curve_edit(mut self, op: Int, idx: Int, point: Vec3, key: Int = 0) raises:
        """Insert (op 0) a point at `idx`, move (1) point `idx` to `point`, or remove (2) point `idx`."""
        if self.playing:
            raise Error("edit refused while playing; stop first")
        var n = len(self.curve)
        if op == 0:
            if idx < 0 or idx > n:
                raise Error("curve: insert index " + String(idx) + " is outside 0.." + String(n))
            self.curve.insert(idx, point)
            self.curve_past.append(CurveStep(0, idx, Vec3(0, 0, 0, 0), point, key))
        elif op == 1:
            if idx < 0 or idx >= n:
                raise Error("curve: point " + String(idx) + " does not exist (" + String(n) + " points)")
            var before = self.curve[idx]
            if before == point:
                return
            self.curve[idx] = point
            var merge = (
                key != 0 and len(self.order) > 0 and self.order[len(self.order) - 1] == 1 and len(self.curve_past) > 0
                and self.curve_past[len(self.curve_past) - 1].op == 1 and self.curve_past[len(self.curve_past) - 1].idx == idx
                and self.curve_past[len(self.curve_past) - 1].key == key and len(self.redo_order) == 0
            )
            if merge:
                self.curve_past[len(self.curve_past) - 1].after = point
                if self.curve_past[len(self.curve_past) - 1].before == point:  # dragged back to where it started
                    _ = self.curve_past.pop()
                    _ = self.order.pop()
                return
            self.curve_past.append(CurveStep(1, idx, before, point, key))
        else:
            if idx < 0 or idx >= n:
                raise Error("curve: point " + String(idx) + " does not exist (" + String(n) + " points)")
            var before = self.curve[idx]
            _ = self.curve.pop(idx)
            self.curve_past.append(CurveStep(2, idx, before, Vec3(0, 0, 0, 0), key))
        self._new_step(1)

    # ---- the node graph (#20): snapshot steps in the same history; an edit is made on a copy first, so a failing
    # command leaves the graph and the history as they were

    def graph_commit(mut self, var edited: Graph, merge_key: String = String()) raises:
        var before = len(self.graph_hist.past)
        self.graph_hist.record(self.graph, merge_key)
        self.graph = edited^
        if len(self.graph_hist.past) > before:  # a merged drag adds no step
            self.order.append(2)
            self.redo_order = List[Int]()
            self.curve_future = List[CurveStep]()

    def _curve_apply(mut self, st: CurveStep, forward: Bool) raises:
        if st.op == 1:
            self.curve[st.idx] = st.after if forward else st.before
        elif (st.op == 0) == forward:
            self.curve.insert(st.idx, st.after if st.op == 0 else st.before)
        else:
            _ = self.curve.pop(st.idx)

    def undo(mut self) raises -> Bool:
        """Undo the latest step of either history. False when there is nothing to undo."""
        if len(self.order) == 0:
            return False
        var kind = self.order[len(self.order) - 1]
        if kind == 0:
            if not self.log.undo(self.world):
                return False
        elif kind == 2:
            if not self.graph_hist.undo(self.graph):
                return False
        else:
            var st = self.curve_past.pop()
            self._curve_apply(st, False)
            self.curve_future.append(st^)
        _ = self.order.pop()
        self.redo_order.append(kind)
        return True

    def redo(mut self) raises -> Bool:
        if len(self.redo_order) == 0:
            return False
        var kind = self.redo_order[len(self.redo_order) - 1]
        if kind == 0:
            if not self.log.redo(self.world):
                return False
        elif kind == 2:
            if not self.graph_hist.redo(self.graph):
                return False
        else:
            var st = self.curve_future.pop()
            self._curve_apply(st, True)
            self.curve_past.append(st^)
        _ = self.redo_order.pop()
        self.order.append(kind)
        return True

    def can_undo(self) -> Bool:
        return len(self.order) > 0

    def can_redo(self) -> Bool:
        return len(self.redo_order) > 0

    def undo_name(self) -> String:
        if len(self.order) == 0:
            return String()
        var k = self.order[len(self.order) - 1]
        if k == 0:
            return self.log.undo_name()
        return String("graph") if k == 2 else String("curve")
