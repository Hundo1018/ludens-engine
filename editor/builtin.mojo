"""Built-in commands. They are plugins like any other: they conform to `editor.ext.Command` and nothing else
reaches them (ludens-shell #18)."""
from editor.ext import Command
from editor.state import Editor
from geometry.vec import Real, Vec3


struct MoveBody(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "move_body"

    @staticmethod
    def source() -> String:
        return "editor.builtin"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """move_body <handle> <x> <y> <z>: place a body at a position, keeping its rotation."""
        if len(args) != 4:
            raise Error("move_body: expected <handle> <x> <y> <z>, got " + String(len(args)) + " arguments")
        var handle = Int64(Int(args[0]))
        var pos = Vec3(Real(Float64(args[1])), Real(Float64(args[2])), Real(Float64(args[3])), 0.0)
        var rot = ed.world.state(handle).rot
        ed.begin("move_body")
        ed.touch(handle)
        ed.world.teleport(handle, pos, rot)
        ed.commit()
