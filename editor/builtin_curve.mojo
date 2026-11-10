"""Curve editing commands (ludens-engine #19): registered through `editor.ext` like any plugin's commands."""
from editor.ext import Command
from editor.state import Editor
from geometry.vec import Real, Vec3


def _num(text: String, what: String) raises -> Real:
    try:
        return Real(Float64(text))
    except:
        raise Error("curve: " + what + " must be a number, got `" + text + "`")


def _int(text: String, what: String) raises -> Int:
    try:
        return Int(text)
    except:
        raise Error("curve: " + what + " must be a whole number, got `" + text + "`")


struct CurveAdd(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "curve_add"

    @staticmethod
    def source() -> String:
        return "editor.builtin_curve"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """curve_add <x> <y> <z> [index]: insert a control point (at the end when no index is given)."""
        if len(args) < 3 or len(args) > 4:
            raise Error("curve_add: expected <x> <y> <z> [index]")
        var at = len(ed.curve) if len(args) == 3 else _int(args[3], "index")
        ed.curve_edit(0, at, Vec3(_num(args[0], "x"), _num(args[1], "y"), _num(args[2], "z"), 0))


struct CurveMove(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "curve_move"

    @staticmethod
    def source() -> String:
        return "editor.builtin_curve"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """curve_move <index> <x> <y> <z> [drag]: move a control point; consecutive `drag` moves of one point are one
        undo step."""
        if len(args) < 4 or len(args) > 5 or (len(args) == 5 and args[4] != "drag"):
            raise Error("curve_move: expected <index> <x> <y> <z> [drag]")
        ed.curve_edit(1, _int(args[0], "index"), Vec3(_num(args[1], "x"), _num(args[2], "y"), _num(args[3], "z"), 0), 1 if len(args) == 5 else 0)


struct CurveDelete(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "curve_delete"

    @staticmethod
    def source() -> String:
        return "editor.builtin_curve"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """curve_delete <index>: remove a control point."""
        if len(args) != 1:
            raise Error("curve_delete: expected <index>")
        ed.curve_edit(2, _int(args[0], "index"), Vec3(0, 0, 0, 0))
