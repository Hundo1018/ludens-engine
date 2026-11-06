"""Node graph editing commands (ludens-shell #20): registered through `editor.ext` like any plugin's commands.

Each command edits a copy of the graph and hands it to `Editor.graph_commit`, so an argument error leaves the graph
and the undo history untouched."""
from editor.ext import Command
from editor.state import Editor


def _int(text: String, what: String) raises -> Int:
    try:
        return Int(text)
    except:
        raise Error("graph: " + what + " must be a whole number, got `" + text + "`")


def _port(text: String, what: String) raises -> Tuple[Int, String]:
    var parts = text.split(".")
    if len(parts) != 2:
        raise Error("graph: " + what + " must be <node>.<port>, got `" + text + "`")
    return (_int(String(parts[0]), what + " node"), String(parts[1]))


struct GraphAdd(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "graph_add"

    @staticmethod
    def source() -> String:
        return "editor.builtin_graph"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """graph_add <id> <kind>: add a node."""
        if len(args) != 2:
            raise Error("graph_add: expected <id> <kind>")
        var g = ed.graph.copy()
        g.add_node(_int(args[0], "id"), args[1])
        ed.graph_commit(g^)


struct GraphSet(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "graph_set"

    @staticmethod
    def source() -> String:
        return "editor.builtin_graph"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """graph_set <id> <key> <value> [drag]: set a node parameter; consecutive `drag` sets of one parameter are one
        undo step."""
        if len(args) < 3 or len(args) > 4 or (len(args) == 4 and args[3] != "drag"):
            raise Error("graph_set: expected <id> <key> <value> [drag]")
        var g = ed.graph.copy()
        g.set_param(_int(args[0], "id"), args[1], args[2])
        ed.graph_commit(g^, (args[0] + ":" + args[1]) if len(args) == 4 else String())


struct GraphConnect(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "graph_connect"

    @staticmethod
    def source() -> String:
        return "editor.builtin_graph"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """graph_connect <node>.<port> <node>.<port>: connect an output to an input."""
        if len(args) != 2:
            raise Error("graph_connect: expected <node>.<port> <node>.<port>")
        var a = _port(args[0], "source")
        var b = _port(args[1], "target")
        var g = ed.graph.copy()
        g.connect(a[0], a[1], b[0], b[1])
        ed.graph_commit(g^)


struct GraphDisconnect(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "graph_disconnect"

    @staticmethod
    def source() -> String:
        return "editor.builtin_graph"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """graph_disconnect <node>.<port>: remove the edge into an input."""
        if len(args) != 1:
            raise Error("graph_disconnect: expected <node>.<port>")
        var b = _port(args[0], "input")
        var g = ed.graph.copy()
        g.disconnect(b[0], b[1])
        ed.graph_commit(g^)


struct GraphRemove(Command):
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "graph_remove"

    @staticmethod
    def source() -> String:
        return "editor.builtin_graph"

    def run(self, mut ed: Editor, args: List[String]) raises:
        """graph_remove <id>: remove a node and the edges that touch it."""
        if len(args) != 1:
            raise Error("graph_remove: expected <id>")
        var g = ed.graph.copy()
        g.remove_node(_int(args[0], "id"))
        ed.graph_commit(g^)
