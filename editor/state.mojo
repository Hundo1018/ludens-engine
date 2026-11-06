"""The editor's state: the world being edited and its undo history (ludens-shell #6, #10).

Undo and redo are the engine's transaction layer (`embed.undo.UndoLog`, ludens-engine 17.43): a command opens a
transaction, tells the editor which bodies it is about to change, changes them, and commits; the log keeps each
body's record from before and after, so one mechanism covers every kind of edit. Commands do not touch the log
directly; they use `begin`, `touch`, `created` and `commit` here, and `Registry.run` aborts an open transaction when
a command fails, so a failed command leaves the world and the history as they were."""
from embed.undo import UndoLog
from embed.world import EmbedWorld


struct Editor(Movable):
    var world: EmbedWorld
    var log: UndoLog
    var playing: Bool
    var play_blob: List[UInt8]  # the world as it was when play started
    var selection: List[Int64]  # selected body handles, in selection order

    def __init__(out self, var world: EmbedWorld):
        self.world = world^
        self.log = UndoLog()
        self.playing = False
        self.play_blob = List[UInt8]()
        self.selection = List[Int64]()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.log = move.log^
        self.playing = move.playing
        self.play_blob = move.play_blob^
        self.selection = move.selection^

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
        self.log.begin(name, merge_key)

    def touch(mut self, h: Int64) raises:
        """Call before changing body `h` inside a transaction."""
        self.log.touch(self.world, h)

    def created(mut self, h: Int64) raises:
        """Call right after adding body `h` inside a transaction."""
        self.log.created(self.world, h)

    def commit(mut self) raises:
        self.log.commit(self.world)

    def abort(mut self) raises:
        if self.log.depth > 0:
            self.log.abort(self.world)

    def undo(mut self) raises -> Bool:
        """Undo the latest step. False when there is nothing to undo."""
        return self.log.undo(self.world)

    def redo(mut self) raises -> Bool:
        return self.log.redo(self.world)

    def can_undo(self) -> Bool:
        return self.log.can_undo()

    def can_redo(self) -> Bool:
        return self.log.can_redo()

    def undo_name(self) -> String:
        return self.log.undo_name()
