"""Built-in commands. They are plugins like any other: they conform to `editor.ext.Command` and nothing else
reaches them (ludens-engine #18)."""
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


struct Play(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "play"

    @staticmethod
    def source() -> String:
        return "editor.builtin"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """play: keep a snapshot and let the world run (see `tick`, `stop`)."""
        if len(args) != 0:
            raise Error("play: takes no arguments")
        ed.play_begin()


struct Tick(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "tick"

    @staticmethod
    def source() -> String:
        return "editor.builtin"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """tick <n>: run n ticks while playing."""
        if len(args) != 1:
            raise Error("tick: expected <n>")
        var n = Int(args[0])
        if n < 0:
            raise Error("tick: n must be >= 0")
        ed.play_ticks(n)


struct Stop(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "stop"

    @staticmethod
    def source() -> String:
        return "editor.builtin"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """stop: restore the world to the moment `play` was called."""
        if len(args) != 0:
            raise Error("stop: takes no arguments")
        ed.play_stop()


struct Select(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "select"

    @staticmethod
    def source() -> String:
        return "editor.builtin"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """select <handle> [add]: select a body (alone, or added to the selection)."""
        if len(args) < 1 or len(args) > 2 or (len(args) == 2 and args[1] != "add"):
            raise Error("select: expected <handle> [add]")
        ed.select(Int64(Int(args[0])), len(args) == 2)
