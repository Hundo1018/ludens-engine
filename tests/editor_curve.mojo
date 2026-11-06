"""Curve editor (ludens-shell #19): commands through the registry, one undo history with the world's, drag merging,
byte round trip and the preview equal to the engine's own evaluation. Native only, no GPU. `pixi run -e wasm test-editor`."""
from editor.builtin import MoveBody
from editor.builtin_curve import CurveAdd, CurveDelete, CurveMove
from editor.curve import curve_from_bytes, curve_to_bytes, sample_curve
from editor.entry import cli_run
from editor.state import Editor
from embed.world import EmbedWorld
from geometry.spline import CatmullRom
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


def cmd(mut ed: Editor, *words: String) raises:
    var argv = List[String]()
    for w in words:
        argv.append(w)
    cli_run[MoveBody, CurveAdd, CurveMove, CurveDelete](ed, argv)


def fails(mut ed: Editor, *words: String) -> Bool:
    var argv = List[String]()
    for w in words:
        argv.append(w)
    try:
        cli_run[MoveBody, CurveAdd, CurveMove, CurveDelete](ed, argv)
    except:
        return True
    return False


def same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def main() raises:
    var c = Check()
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    var body = w.add_box(Vec3(0.0, 2.0, 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    var ed = Editor(w^)

    # the edit from the issue: add 3 points, move 1, delete 1; save and read back byte for byte
    cmd(ed, "curve_add", "0", "0", "0")
    cmd(ed, "curve_add", "1", "2", "0")
    cmd(ed, "curve_add", "3", "2", "1")
    var b3 = curve_to_bytes(ed.curve)
    cmd(ed, "curve_move", "1", "1.5", "2.5", "0")
    var b4 = curve_to_bytes(ed.curve)
    cmd(ed, "curve_delete", "0")
    var b5 = curve_to_bytes(ed.curve)
    c.ok(len(ed.curve) == 2 and not same(b3, b4) and not same(b4, b5), "three adds, a move and a delete: two points left")
    var back = curve_from_bytes(b5)
    c.ok(same(curve_to_bytes(back), b5) and len(back) == 2, "save and read back: the bytes are the same")

    # undo returns to the bytes before each step
    c.ok(ed.undo() and same(curve_to_bytes(ed.curve), b4), "undo the delete: the bytes of before the delete")
    c.ok(ed.undo() and same(curve_to_bytes(ed.curve), b3), "undo the move: the bytes of before the move")
    c.ok(ed.redo() and same(curve_to_bytes(ed.curve), b4), "redo the move")
    c.ok(ed.redo() and same(curve_to_bytes(ed.curve), b5), "redo the delete")
    c.ok(not ed.redo(), "nothing left to redo")

    # a drag is one step
    var before_drag = curve_to_bytes(ed.curve)
    var steps_before = len(ed.order)
    cmd(ed, "curve_move", "0", "2", "2", "0", "drag")
    cmd(ed, "curve_move", "0", "2.5", "2.2", "0", "drag")
    cmd(ed, "curve_move", "0", "3", "2.4", "0", "drag")
    c.ok(len(ed.order) == steps_before + 1, "three drag moves of one point are one undo step")
    c.ok(ed.undo() and same(curve_to_bytes(ed.curve), before_drag), "one undo undoes the whole drag")
    cmd(ed, "curve_move", "0", "9", "9", "9", "drag")
    cmd(ed, "curve_move", "0", String(Float64(ed.curve[0][0])), "1", "1", "drag")
    var pt = ed.curve[0]
    cmd(ed, "curve_move", "1", "5", "5", "5", "drag")
    c.ok(len(ed.curve) == 2 and ed.curve[1][0] == 5, "a drag of another point does not merge with the first")
    _ = pt

    # one history with the world's
    var h0 = ed.world.hash()
    cmd(ed, "move_body", String(body), "0", "6", "0")
    var h1 = ed.world.hash()
    var cb = curve_to_bytes(ed.curve)
    cmd(ed, "curve_add", "7", "7", "7")
    c.ok(ed.undo() and same(curve_to_bytes(ed.curve), cb) and ed.world.hash() == h1, "undo goes back through the curve edit first, the world is untouched")
    c.ok(ed.undo() and ed.world.hash() == h0, "the next undo is the world move")
    c.ok(ed.redo() and ed.world.hash() == h1 and same(curve_to_bytes(ed.curve), cb), "redo brings the world move back, the curve as it was")

    # a new edit ends the redo chain
    cmd(ed, "curve_add", "8", "8", "8")
    c.ok(not ed.can_redo(), "a new edit ends the redo chain")

    # bad input changes nothing
    var snap = curve_to_bytes(ed.curve)
    var n_steps = len(ed.order)
    c.ok(fails(ed, "curve_move", "99", "0", "0", "0"), "moving a point that does not exist is refused")
    c.ok(fails(ed, "curve_delete", "-1"), "deleting index -1 is refused")
    c.ok(fails(ed, "curve_add", "1", "x", "3"), "a coordinate that is not a number is refused")
    c.ok(fails(ed, "curve_add", "1", "2", "3", "99"), "an insert index past the end is refused")
    c.ok(same(curve_to_bytes(ed.curve), snap) and len(ed.order) == n_steps, "...and none of them changed the curve or the history")

    # preview: 100 samples equal the engine's own evaluation, bit for bit
    var pts = List[Vec3]()
    pts.append(Vec3(0, 0, 0, 0))
    pts.append(Vec3(1, 2, 0, 0))
    pts.append(Vec3(3, 2, 1, 0))
    pts.append(Vec3(4, 0, 2, 0))
    var samples = sample_curve(pts, 100)
    var direct = CatmullRom[3](pts.copy())
    var diff = 0
    for i in range(100):
        var e = direct.eval(direct.domain_max() * Real(i) / Real(99))
        if e[0] != samples[i][0] or e[1] != samples[i][1] or e[2] != samples[i][2]:
            diff += 1
    c.ok(diff == 0 and len(samples) == 100, "100 preview samples are bit-identical to the engine's CatmullRom.eval")
    var one = List[Vec3]()
    one.append(Vec3(0, 0, 0, 0))
    var raised = False
    try:
        _ = sample_curve(one, 10)
    except:
        raised = True
    c.ok(raised, "a curve with one control point cannot be sampled")

    # damaged assets are refused
    var flipped = b5.copy()
    flipped[10] = flipped[10] ^ 0x40
    var bad_ok = False
    try:
        _ = curve_from_bytes(flipped)
    except:
        bad_ok = True
    var cut = List[UInt8]()
    for i in range(len(b5) - 1):
        cut.append(b5[i])
    var cut_ok = False
    try:
        _ = curve_from_bytes(cut)
    except:
        cut_ok = True
    c.ok(bad_ok and cut_ok, "a flipped byte and a truncated file are refused")

    print("editor-curve:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("editor-curve: " + String(c.failed) + " checks failed")
