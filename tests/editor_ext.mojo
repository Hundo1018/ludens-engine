"""Extension API, command registration (ludens-shell #18): registry order, duplicate names, a plugin command.

The plugin here is a struct in this file that conforms to `Command` and touches only the `Editor` it is handed,
which is all a package outside the repository can do. Native only, no GPU. `pixi run -e wasm test-editor`."""
from editor.builtin import MoveBody
from editor.entry import cli_run
from editor.ext import Command, Registry
from editor.state import Editor, Inverse
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3


struct Lift(Command):
    """Raise a body by dy: `lift <handle> <dy>`. Records its inverse like a built-in."""
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "lift"

    @staticmethod
    def source() -> String:
        return "plugin.lift"

    def run(self, mut ed: Editor, args: List[String]) raises:
        if len(args) != 2:
            raise Error("lift: expected <handle> <dy>")
        var h = Int64(Int(args[0]))
        var before = ed.world.state(h)
        ed.world.teleport(h, Vec3(before.pos[0], before.pos[1] + Real(Float64(args[1])), before.pos[2], 0.0), before.rot)
        ed.undo_stack.append(Inverse(h, before.pos, before.rot))


struct ShadowMove(Command):
    """A second plugin that registers a name the built-ins already use."""
    def __init__(out self):
        pass

    @staticmethod
    def name() -> String:
        return "move_body"

    @staticmethod
    def source() -> String:
        return "plugin.shadow"

    def run(self, mut ed: Editor, args: List[String]) raises:
        pass


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
            print("  [PASS]", label)
        else:
            self.failed += 1
            print("  [FAIL]", label)


def make_world(mut handles: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    handles.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    handles.append(w.add_box(Vec3(0.0, 2.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def argv(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(x)
    return out^


def main() raises:
    var c = Check()

    # 1. Registration order is the order of the type parameters, and it is the same on every call.
    comptime A = Registry[MoveBody, Lift]
    comptime B = Registry[Lift, MoveBody]
    var na = A.names()
    var nb = B.names()
    c.ok(len(na) == 2 and na[0] == "move_body" and na[1] == "lift", "registration order: built-in first, then the plugin")
    c.ok(nb[0] == "lift" and nb[1] == "move_body", "the other order lists the other way round")
    c.ok(A.names()[1] == na[1] and A.sources()[1] == "plugin.lift", "names and sources are stable between calls")

    # 2. Duplicate names fail the build step and name both packages.
    A.check()
    c.ok(True, "distinct names pass the check")
    comptime D = Registry[MoveBody, Lift, ShadowMove]
    var msg = String()
    try:
        D.check()
    except e:
        msg = String(e)
    c.ok("move_body" in msg and "editor.builtin" in msg and "plugin.shadow" in msg, "duplicate: names the command and both sources (" + msg + ")")

    # 3. A plugin command goes through the same entry as a built-in; the world matches the equivalent built-in call.
    var h1 = List[Int64]()
    var via_plugin = Editor(make_world(h1))
    cli_run[MoveBody, Lift](via_plugin, argv("lift", String(h1[1]), "1.5"))
    var h2 = List[Int64]()
    var via_builtin = Editor(make_world(h2))
    cli_run[MoveBody, Lift](via_builtin, argv("move_body", String(h2[1]), "0", "3.5", "0"))
    c.ok(via_plugin.world.hash() == via_builtin.world.hash(), "lift 1.5 gives the world of move_body to y + 1.5 (same hash)")
    c.ok(len(via_plugin.undo_stack) == 1 and via_plugin.undo(), "the plugin's inverse is on the editor's undo stack and undo works")

    # 4. A registry without the plugin refuses its command, and the world is unchanged.
    var h3 = List[Int64]()
    var plain = Editor(make_world(h3))
    var before = plain.world.hash()
    var refused = False
    try:
        cli_run[MoveBody](plain, argv("lift", String(h3[1]), "1"))
    except e:
        refused = "unknown command: lift" in String(e)
    c.ok(refused and plain.world.hash() == before, "a build without the plugin: unknown command, world unchanged")

    # 5. A plugin command that fails leaves the world as it was.
    var h4 = List[Int64]()
    var ed = Editor(make_world(h4))
    var before4 = ed.world.hash()
    var raised = False
    try:
        cli_run[MoveBody, Lift](ed, argv("lift", String(h4[1])))
    except:
        raised = True
    c.ok(raised and ed.world.hash() == before4 and len(ed.undo_stack) == 0, "a plugin error leaves the world and the undo stack unchanged")

    print("editor-ext:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("editor-ext: " + String(c.failed) + " checks failed")
