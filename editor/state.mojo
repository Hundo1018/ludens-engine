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

    def __init__(out self, var world: EmbedWorld):
        self.world = world^
        self.log = UndoLog()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.log = move.log^

    def begin(mut self, name: String, merge_key: Int = 0) raises:
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
