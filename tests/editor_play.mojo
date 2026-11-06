"""Play in editor and selection (ludens-shell #10): run the world, stop, and it is exactly as it was.
Native only, no GPU. `pixi run -e wasm test-editor`."""
from editor.builtin import MoveBody, Play, Select, Stop, Tick
from editor.entry import cli_run
from editor.state import Editor
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3


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


def make_world(mut hs: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    hs.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    for i in range(5):
        hs.append(w.add_box(Vec3(Real(i) * 1.2 - 2.4, 2.0 + Real(i) * 1.1, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def cmd(mut ed: Editor, *words: String) raises:
    var argv = List[String]()
    for w in words:
        argv.append(w)
    cli_run[MoveBody, Play, Tick, Stop, Select](ed, argv)


def fails(mut ed: Editor, *words: String) -> Bool:
    var argv = List[String]()
    for w in words:
        argv.append(w)
    try:
        cli_run[MoveBody, Play, Tick, Stop, Select](ed, argv)
    except:
        return True
    return False


def main() raises:
    var c = Check()
    var hs = List[Int64]()
    var ed = Editor(make_world(hs))
    var h0 = ed.world.hash()

    # play 300 ticks, stop: the world hash is the one before play
    cmd(ed, "play")
    cmd(ed, "tick", "300")
    c.ok(ed.world.hash() != h0, "while playing the world changed (the boxes fell)")
    cmd(ed, "stop")
    c.ok(ed.world.hash() == h0, "after stop the world hash equals the one before play")
    c.ok(not ed.playing, "not playing after stop")

    # an unedited world run the same 300 ticks differs from the stopped one only by those ticks: play is repeatable
    cmd(ed, "play")
    cmd(ed, "tick", "300")
    var run1 = ed.world.hash()
    cmd(ed, "stop")
    cmd(ed, "play")
    cmd(ed, "tick", "300")
    c.ok(ed.world.hash() == run1, "playing twice gives the same world after 300 ticks")
    cmd(ed, "stop")

    # edits and mistakes while playing
    cmd(ed, "play")
    c.ok(fails(ed, "move_body", String(hs[1]), "0", "5", "0"), "an edit while playing is refused")
    c.ok(fails(ed, "play"), "play while playing is refused")
    cmd(ed, "stop")
    c.ok(fails(ed, "stop"), "stop when not playing is refused")
    c.ok(fails(ed, "tick", "5"), "tick when not playing is refused")
    c.ok(ed.world.hash() == h0, "the refused commands changed nothing")
    cmd(ed, "move_body", String(hs[1]), "0", "5", "0")
    c.ok(ed.undo(), "edits work again after stop, and undo")

    # selection
    cmd(ed, "select", String(hs[2]))
    cmd(ed, "select", String(hs[3]), "add")
    c.ok(len(ed.selection) == 2 and ed.is_selected(hs[2]) and ed.is_selected(hs[3]), "select and select add")
    cmd(ed, "select", String(hs[2]), "add")
    c.ok(len(ed.selection) == 2, "adding a selected body again does nothing")
    cmd(ed, "select", String(hs[4]))
    c.ok(len(ed.selection) == 1 and ed.is_selected(hs[4]), "select without add replaces the selection")
    ed.world.remove(hs[4])
    ed.prune_selection()
    c.ok(len(ed.selection) == 0, "a removed body leaves the selection after prune")
    c.ok(fails(ed, "select", String(hs[4])), "selecting a removed body is refused")
    c.ok(fails(ed, "select", "x"), "a handle that is not a number is refused")

    print("editor-play:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("editor-play: " + String(c.failed) + " checks failed")
