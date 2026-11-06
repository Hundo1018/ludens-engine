"""Scene hot reload (ludens-shell #14): the new scene replaces the world at the current tick, a bad file changes
nothing. Native only, no GPU. `pixi run -e wasm test-editor`."""
from editor.builtin import MoveBody
from editor.reload import reload_scene, world_from_text
from editor.scene_text import scene_rows_to_text
from editor.state import Editor
from embed.scene_io import export_scene, scene_to_fields
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


def make_world(mut hs: List[Int64], top: Real) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    hs.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    for i in range(4):
        hs.append(w.add_box(Vec3(Real(i) * 1.2 - 1.8, top + Real(i) * 1.1, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def run(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()


def text_of(w: EmbedWorld) raises -> String:
    return scene_rows_to_text(scene_to_fields(export_scene(w)))


def main() raises:
    var c = Check()
    var hs = List[Int64]()
    var ed = Editor(make_world(hs, 2.0))
    run(ed.world, 60)
    var tick = ed.world.tick

    # a changed scene (the boxes start higher) replaces the world at the same tick
    var hn = List[Int64]()
    var new_text = text_of(make_world(hn, 5.0))
    reload_scene(ed, new_text)
    var restart = world_from_text(new_text)
    run(restart, 60)
    c.ok(ed.world.tick == tick and restart.tick == tick, "the reloaded world is at the same tick as before")
    c.ok(ed.world.hash() == restart.hash(), "its hash equals a restart with the new scene run to that tick")
    c.ok(len(ed.messages) == 1 and "reloaded" in ed.messages[0], "the log says it reloaded")

    # a bad file changes nothing and is reported
    var before = ed.world.hash()
    var bad = new_text.replace("version = 1", "this line has no equals sign")
    var raised = False
    try:
        reload_scene(ed, bad)
    except e:
        raised = "reload failed" in String(e)
    c.ok(raised, "a malformed scene raises")
    c.ok(ed.world.hash() == before, "...and the old world is untouched")
    c.ok(len(ed.messages) == 2 and "reload failed" in ed.messages[1], "...and the error is in the log")
    var empty_raised = False
    try:
        reload_scene(ed, "")
    except:
        empty_raised = True
    c.ok(empty_raised and ed.world.hash() == before, "an empty file is refused, world untouched")

    # undo history and selection
    var hs2 = List[Int64]()
    var ed2 = Editor(make_world(hs2, 2.0))
    var argv = List[String]()
    argv.append(String(hs2[1]))
    argv.append("0")
    argv.append("9")
    argv.append("0")
    var mv = MoveBody()
    mv.run(ed2, argv)
    c.ok(ed2.can_undo(), "an edit is on the undo stack")
    ed2.select(hs2[1])
    ed2.select(hs2[4], True)
    var hn2 = List[Int64]()
    var smaller = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = smaller.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
    _ = smaller.add_box(Vec3(0.0, 2.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    reload_scene(ed2, text_of(smaller))
    c.ok(not ed2.can_undo(), "the undo history is cleared by a reload")
    c.ok(len(ed2.selection) == 1 and ed2.is_selected(hs2[1]) and not ed2.is_selected(hs2[4]), "the selection keeps the body that is still alive and drops the one that is gone")

    # refused while playing
    var hs3 = List[Int64]()
    var ed3 = Editor(make_world(hs3, 2.0))
    ed3.play_begin()
    var refused = False
    try:
        reload_scene(ed3, new_text)
    except:
        refused = True
    c.ok(refused, "reload while playing is refused")

    # unchanged text at tick 0 gives the same hash
    var hs4 = List[Int64]()
    var ed4 = Editor(make_world(hs4, 2.0))
    var h0 = ed4.world.hash()
    reload_scene(ed4, text_of(ed4.world))
    c.ok(ed4.world.hash() == h0, "reloading the unchanged scene at tick 0 leaves the hash as it was")

    print("editor-reload:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("editor-reload: " + String(c.failed) + " checks failed")
