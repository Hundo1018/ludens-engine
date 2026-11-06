"""Editor command layer (ludens-shell #6, E1).

Every editing operation is a command: a name plus text arguments. Text is the one canonical form. The CLI
passes argv as it is and the GUI formats its typed values to text, so both reach the same parser and the same
code, and a GUI action can be replayed from a script.

A command that changes the world records its inverse so it can be undone. The record kept here is the
previous pose of one body; engine 17.43 (ludens-engine #83) replaces the per-command record with its
transaction layer, and #18 replaces the name dispatch in `Editor.execute` with registration points.
"""
from embed.world import EmbedWorld
from geometry.quat import Quat
from geometry.vec import Real, Vec3


@fieldwise_init
struct Inverse(Copyable, ImplicitlyCopyable, Movable):
    """What `undo` needs to put one body back where `move_body` found it."""
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

    def execute(mut self, name: String, args: List[String]) raises:
        """Run one command. Errors name the command and leave the world and the undo stack unchanged."""
        if name == "move_body":
            self._move_body(args)
        else:
            raise Error("unknown command: " + name)

    def undo(mut self) raises -> Bool:
        """Undo the latest command. False when there is nothing to undo."""
        if len(self.undo_stack) == 0:
            return False
        var inv = self.undo_stack.pop()
        self.world.teleport(inv.handle, inv.pos, inv.rot)
        return True

    def _move_body(mut self, args: List[String]) raises:
        """move_body <handle> <x> <y> <z>: place a body at a position, keeping its rotation."""
        if len(args) != 4:
            raise Error("move_body: expected <handle> <x> <y> <z>, got " + String(len(args)) + " arguments")
        var handle = Int64(Int(args[0]))
        var pos = Vec3(Real(Float64(args[1])), Real(Float64(args[2])), Real(Float64(args[3])), 0.0)
        var before = self.world.state(handle)
        self.world.teleport(handle, pos, before.rot)
        self.undo_stack.append(Inverse(handle, before.pos, before.rot))
