"""Command layer test (ludens-engine #6): GUI and CLI entry points give the same world, and undo works.

Native only, no GPU. Build and run: `pixi run -e wasm test-editor`."""
from editor.builtin import MoveBody
from editor.ext import Registry
from editor.state import Editor
from editor.entry import cli_run, gui_move_body
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


def make_world(mut handles: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    handles.append(w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True))
    for i in range(4):
        var x = Real(i) * 1.2 - 1.8
        handles.append(w.add_box(Vec3(x, Real(2 + i) * 1.1, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
    return w^


def run_ticks(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()


def main() raises:
    var c = Check()

    # 1. The same move through the GUI entry and through the CLI entry.
    var ha = List[Int64]()
    var hb = List[Int64]()
    var hc = List[Int64]()
    var gui = Editor(make_world(ha))
    var cli = Editor(make_world(hb))
    var untouched = make_world(hc)
    var target = ha[3]
    gui_move_body[MoveBody](gui, target, Vec3(0.7, 3.0, -0.3, 0.0))
    var argv = List[String]()
    argv.append("move_body")
    argv.append(String(hb[3]))
    argv.append("0.7")
    argv.append("3.0")
    argv.append("-0.3")
    cli_run[MoveBody](cli, argv)
    c.ok(gui.world.hash() == cli.world.hash(), "GUI and CLI entries: same world hash right after the command")
    c.ok(gui.world.hash() != untouched.hash(), "the command changed the world")
    # Control: a CLI argument that differs by 1e-7 must give a different hash, or the equality above proves nothing.
    var hd = List[Int64]()
    var off_by_a_bit = Editor(make_world(hd))
    var argv2 = List[String]()
    argv2.append("move_body")
    argv2.append(String(hd[3]))
    argv2.append("0.7000001")
    argv2.append("3.0")
    argv2.append("-0.3")
    cli_run[MoveBody](off_by_a_bit, argv2)
    c.ok(off_by_a_bit.world.hash() != gui.world.hash(), "control: an argument 1e-7 away gives a different hash")
    run_ticks(gui.world, 120)
    run_ticks(cli.world, 120)
    c.ok(gui.world.hash() == cli.world.hash(), "GUI and CLI entries: same world hash after 120 more ticks")

    # 2. Text loses nothing: values that are not exact in decimal survive the round trip through the command text.
    var h1 = List[Int64]()
    var h2 = List[Int64]()
    var via_text = Editor(make_world(h1))
    var direct = make_world(h2)
    var p = Vec3(Real(1.0 / 3.0), Real(2.0 / 7.0), Real(-0.1), 0.0)
    gui_move_body[MoveBody](via_text, h1[2], p)
    var st = direct.state(h2[2])
    direct.teleport(h2[2], p, st.rot)
    c.ok(via_text.world.hash() == direct.hash(), "text round trip equals a direct teleport (1/3, 2/7, -0.1)")

    # 3. Undo puts the pose back. (Engine 17.43 is the full-state version; see the hash line below.)
    var h3 = List[Int64]()
    var ed = Editor(make_world(h3))
    var pose0 = ed.world.state(h3[2])
    var hash0 = ed.world.hash()
    gui_move_body[MoveBody](ed, h3[2], Vec3(5.0, 6.0, 7.0, 0.0))
    var moved = ed.world.state(h3[2])
    c.ok(Float64(moved.pos[0]) == 5.0 and Float64(moved.pos[1]) == 6.0 and Float64(moved.pos[2]) == 7.0, "move_body placed the body")
    c.ok(ed.undo(), "undo reports it undid something")
    var pose1 = ed.world.state(h3[2])
    c.ok(
        Float64(pose1.pos[0]) == Float64(pose0.pos[0])
        and Float64(pose1.pos[1]) == Float64(pose0.pos[1])
        and Float64(pose1.pos[2]) == Float64(pose0.pos[2])
        and Float64(pose1.rot.w) == Float64(pose0.rot.w),
        "undo restores the pose bit for bit",
    )
    print("  info: world hash after move + undo equals the hash before:", ed.world.hash() == hash0)
    c.ok(not ed.undo(), "a second undo has nothing to undo")

    # 4. Bad input raises and changes nothing.
    var h4 = List[Int64]()
    var bad = Editor(make_world(h4))
    var before = bad.world.hash()
    var raised = 0
    try:
        Registry[MoveBody].run(bad, "no_such_command", List[String]())
    except:
        raised += 1
    var short = List[String]()
    short.append("1")
    try:
        Registry[MoveBody].run(bad, "move_body", short)
    except:
        raised += 1
    var not_a_number = List[String]()
    not_a_number.append(String(h4[1]))
    not_a_number.append("x")
    not_a_number.append("0")
    not_a_number.append("0")
    try:
        Registry[MoveBody].run(bad, "move_body", not_a_number)
    except:
        raised += 1
    c.ok(raised == 3, "unknown command, wrong argument count and a non-number all raise")
    c.ok(bad.world.hash() == before and bad.log.steps() == 0, "failed commands leave the world and the undo stack unchanged")

    print("editor-command:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("editor-command: " + String(c.failed) + " checks failed")
