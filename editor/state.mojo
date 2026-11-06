"""The editor's state: the world being edited and the stack of inverses (ludens-shell #6).

Commands are not here; they are registered through `editor.ext` (#18) and run against this state."""
from embed.world import EmbedWorld
from geometry.quat import Quat
from geometry.vec import Vec3


@fieldwise_init
struct Inverse(Copyable, ImplicitlyCopyable, Movable):
    """What `undo` needs to put one body back where a command found it."""
    var handle: Int64
    var pos: Vec3
    var rot: Quat


struct Editor(Movable):
    var world: EmbedWorld
    var undo_stack: List[Inverse]

    def __init__(out self, var world: EmbedWorld):
        self.world = world^
        self.undo_stack = List[Inverse]()

    def __init__(out self, *, deinit move: Self):
        self.world = move.world^
        self.undo_stack = move.undo_stack^

    def undo(mut self) raises -> Bool:
        """Undo the latest command. False when there is nothing to undo."""
        if len(self.undo_stack) == 0:
            return False
        var inv = self.undo_stack.pop()
        self.world.teleport(inv.handle, inv.pos, inv.rot)
        return True
