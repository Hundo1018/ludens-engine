"""The native entry of the editor core (`ludens-core`), the process `scripts/ludens.py` drives (ludens-shell #11).

    ludens-core demo   <out.scene>
    ludens-core hash   <scene>
    ludens-core list   <scene>
    ludens-core check  <scene>
    ludens-core run    <scene> <ticks> [-o <out>]
    ludens-core cmd    <scene> [-o <out>] -- <command> <args...>
    ludens-core script <scene> <file> [-o <out>]
    ludens-core gui-move <scene> <handle> <x> <y> <z> [-o <out>]

A scene file is the flat text form of `embed.scene_io`. Commands and scripts edit in place unless `-o` names
another file; nothing is written when a command fails. `gui-move` goes through the GUI entry of the command
layer and `cmd` through the CLI entry, so a test can compare the two across processes.

Exit code: 0 ok, 1 error (message on stderr)."""
from std.sys import argv, exit, stderr
from editor.builtin import MoveBody
from editor.state import Editor
from editor.entry import cli_run, gui_move_body
from editor.scene_text import scene_rows_from_text, scene_rows_to_text
from embed.scene_io import export_scene, import_scene, scene_from_fields, scene_to_fields
from embed.world import EmbedWorld, pack_body
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from physics.capture import CaptureReader, verify

comptime DEMO_DT = 1.0 / 60.0


def hex16(v: UInt64) -> String:
    var digits = String("0123456789abcdef")
    var out = String()
    for i in range(16):
        var shift = UInt64(60 - 4 * i)
        var d = Int((v >> shift) & 15)
        out += String(digits[byte=d : d + 1])
    return out^


def read_file(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def read_bytes(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def write_bytes(path: String, data: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(data)


def write_file(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def load(path: String) raises -> Editor:
    var text = String()
    try:
        text = read_file(path)
    except e:
        raise Error("cannot read `" + path + "`: " + String(e))
    try:
        var doc = scene_from_fields(scene_rows_from_text(text))
        var w = EmbedWorld(doc.dt, doc.gravity)
        import_scene(w, doc)
        return Editor(w^)
    except e:
        raise Error(path + ": " + String(e))


def save(ed: Editor, path: String) raises:
    write_file(path, scene_rows_to_text(scene_to_fields(export_scene(ed.world))))


def demo() raises -> Editor:
    """A floor and a stack of boxes and spheres over it: enough to run, edit and compare."""
    var w = EmbedWorld(DEMO_DT, Vec3(0.0, -9.81, 0.0, 0.0))
    w.set_solver(8, 4)
    _ = w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
    for i in range(4):
        _ = w.add_box(Vec3(Real(i % 2) * 1.2 - 0.6, 0.5 + Real(i) * 1.1, Real(i // 2) * 1.2 - 0.6, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    _ = w.add_sphere(Vec3(0.1, 6.0, 0.0, 0.0), 0.4, 2.0, False)
    _ = w.add_sphere(Vec3(-0.4, 8.0, 0.2, 0.0), 0.3, 1.0, False)
    return Editor(w^)


def run_ticks(mut ed: Editor, n: Int) raises:
    for _ in range(n):
        for _ in range(ed.world.ticks_due(ed.world.dt)):
            ed.world.physics_tick()


def out_path(args: List[String], stop: Int, default: String) -> String:
    """The file after `-o` among args[:stop], else `default`."""
    for i in range(stop - 1):
        if args[i] == "-o":
            return args[i + 1]
    return default


def words(line: String) -> List[String]:
    var out = List[String]()
    var parts = line.split()
    for i in range(len(parts)):
        out.append(String(parts[i]))
    return out^


def report(ed: Editor):
    print("hash", hex16(ed.world.hash()), "bodies", len(ed.world.bodies()))


def real_arg(text: String, what: String) raises -> Float64:
    try:
        return Float64(text)
    except:
        raise Error(what + " must be a number, got `" + text + "`")


def run_command(args: List[String]) raises:
    var sub = args[0]
    if sub == "demo":
        if len(args) != 2:
            raise Error("usage: demo <out.scene>")
        var ed = demo()
        save(ed, args[1])
        report(ed)
    elif sub == "hash" or sub == "check":
        if len(args) != 2:
            raise Error("usage: " + sub + " <scene>")
        var ed = load(args[1])
        report(ed)
    elif sub == "list":
        if len(args) != 2:
            raise Error("usage: list <scene>")
        var ed = load(args[1])
        var hs = ed.world.bodies()
        for i in range(len(hs)):
            var st = ed.world.state(hs[i])
            print(i, hs[i], Float64(st.pos[0]), Float64(st.pos[1]), Float64(st.pos[2]))
    elif sub == "run":
        if len(args) < 3:
            raise Error("usage: run <scene> <ticks> [-o <out>]")
        var ed = load(args[1])
        var n = Int(real_arg(args[2], "ticks"))
        if n < 0:
            raise Error("ticks must be >= 0")
        run_ticks(ed, n)
        report(ed)
        var o = out_path(args, len(args), String())
        if o.byte_length() > 0:
            save(ed, o)
    elif sub == "trace":
        if len(args) != 4:
            raise Error("usage: trace <scene> <ticks> <out.json>")
        var ed = load(args[1])
        var n = Int(real_arg(args[2], "ticks"))
        if n < 0:
            raise Error("ticks must be >= 0")
        run_ticks(ed, n)
        report(ed)
        write_file(args[3], ed.world.scene.trace.to_chrome_json())
    elif sub == "overlay":
        if len(args) != 4:
            raise Error("usage: overlay <scene> <ticks> <out.json>")
        var ed = load(args[1])
        var n = Int(real_arg(args[2], "ticks"))
        if n < 0:
            raise Error("ticks must be >= 0")
        # the physics overlay: one arrow per contact point per step, read and aged once per frame
        var total = 0
        var last = String("[")
        for _ in range(n):
            for _ in range(ed.world.ticks_due(ed.world.dt)):
                ed.world.physics_tick()
            total += ed.world.scene.draw.count()
            var items = String("[")
            var first = True
            for ref c in ed.world.scene.draw.commands:
                if not first:
                    items += ","
                first = False
                items += (
                    "{\"kind\":" + String(c.kind)
                    + ",\"p0\":[" + String(Float64(c.p0[0])) + "," + String(Float64(c.p0[1])) + "," + String(Float64(c.p0[2])) + "]"
                    + ",\"p1\":[" + String(Float64(c.p1[0])) + "," + String(Float64(c.p1[1])) + "," + String(Float64(c.p1[2])) + "]"
                    + ",\"color\":[" + String(Float64(c.color[0])) + "," + String(Float64(c.color[1])) + "," + String(Float64(c.color[2])) + "," + String(Float64(c.color[3])) + "]}"
                )
            last = items + "]"
            ed.world.scene.draw.tick()
        report(ed)
        print("overlay commands:", total)
        write_file(args[3], last)
    elif sub == "capture":
        if len(args) != 4:
            raise Error("usage: capture <scene> <ticks> <out.cap>")
        var ed = load(args[1])
        var n = Int(real_arg(args[2], "ticks"))
        if n < 1:
            raise Error("ticks must be >= 1")
        ed.world.capture_begin(30)
        run_ticks(ed, n)
        ed.world.capture_end()
        write_bytes(args[3], ed.world.capture.to_bytes())
        print("captured", ed.world.capture.frame_count(), "frames")
        report(ed)
    elif sub == "replay":
        if len(args) != 3:
            raise Error("usage: replay <scene> <capture>")
        var ed = load(args[1])
        var rd = CaptureReader(read_bytes(args[2]))
        var first_bad = verify(rd, 0, rd.frame_count(), Real(ed.world.dt), ed.world.gravity, ed.world.cfg)
        if first_bad >= 0:
            print("mismatch at frame", first_bad, "of", rd.frame_count())
            exit(1)
        print("verified", rd.frame_count(), "frames")
    elif sub == "cmd":
        var dash = -1
        for i in range(len(args)):
            if args[i] == "--":
                dash = i
        if len(args) < 3 or dash < 2 or dash + 1 >= len(args):
            raise Error("usage: cmd <scene> [-o <out>] -- <command> <args...>")
        var ed = load(args[1])
        var argv_ = List[String]()
        for i in range(dash + 1, len(args)):
            argv_.append(args[i])
        cli_run[MoveBody](ed, argv_)
        report(ed)
        save(ed, out_path(args, dash, args[1]))
    elif sub == "script":
        if len(args) < 3:
            raise Error("usage: script <scene> <file> [-o <out>]")
        var ed = load(args[1])
        var lines = read_file(args[2]).split("\n")
        for i in range(len(lines)):
            var line = String(lines[i].strip())
            if line.byte_length() == 0 or line.startswith("#"):
                continue
            try:
                var w = words(line)
                if w[0] == "undo":
                    if not ed.undo():
                        raise Error("nothing to undo")
                elif w[0] == "redo":
                    if not ed.redo():
                        raise Error("nothing to redo")
                else:
                    cli_run[MoveBody](ed, w)
            except e:
                raise Error(args[2] + ":" + String(i + 1) + ": " + String(e))
        report(ed)
        save(ed, out_path(args, len(args), args[1]))
    elif sub == "gui-move":
        if len(args) < 6:
            raise Error("usage: gui-move <scene> <handle> <x> <y> <z> [-o <out>]")
        var ed = load(args[1])
        var h = Int64(Int(real_arg(args[2], "handle")))
        var p = Vec3(Real(real_arg(args[3], "x")), Real(real_arg(args[4], "y")), Real(real_arg(args[5], "z")), 0.0)
        gui_move_body[MoveBody](ed, h, p)
        report(ed)
        save(ed, out_path(args, len(args), args[1]))
    else:
        raise Error("unknown subcommand `" + sub + "` (demo, hash, list, check, run, trace, overlay, capture, replay, cmd, script, gui-move)")


def main():
    var a = argv()
    var args = List[String]()
    for i in range(1, len(a)):
        args.append(String(a[i]))
    if len(args) == 0:
        print("ludens-core: expected a subcommand (demo, hash, list, check, run, trace, overlay, capture, replay, cmd, script, gui-move)")
        exit(1)
    try:
        run_command(args)
    except e:
        print("ludens-core:", String(e), file=stderr)
        exit(1)
