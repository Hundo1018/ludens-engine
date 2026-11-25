# tier: integration
"""The in-game console, the cheats and photo mode (issue #146; docs/console.md): what the console accepts and refuses,
that a log played back reaches the same hash as the run that typed it, what each cheat does in the demo game, that the
cheat mark is saved and refuses achievements, photo mode's bound, settings and capture size, and the focal length and
zoom (game/zoom_lens.mojo). Native only:
`pixi run -e wasm test-console` (scripts/test_console.py also builds the release variant, tests/console_release.mojo)."""
from game.cheats import CHEAT_GOD, CHEAT_MARKED, CheatMark
from game.console import CONSOLE_BUILT, CommandSpec, Console, ConsoleLine
from game.demo_mode import DEMO_SAVE_VERSION, DemoMigrator, DemoMode
from game.intent import Intent
from game.mode import GameMode
from game.camera_view import View
from game.photo_camera import MAX_CAPTURE_SIDE, PHOTO_MAX_MM, PHOTO_MIN_MM, PhotoMode
from game.zoom_lens import ZoomLens, focal_from_fov, fov_from_focal
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from platform.achievements import CheatGuard, LocalAchievements
from platform.packets import REQ_CHEATED
from platform.save_store import migrate_payload
from procedural.camera_math import CameraPose
from std.math import sqrt


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
        print("  [" + ("PASS" if cond else "FAIL") + "]", label)


def refused(mut con: Console, line: String) -> String:
    """The error `submit` raised for `line`, or "" if it was accepted."""
    try:
        _ = con.submit(line, 0)
    except e:
        return String(e)
    return String()


def intent_at(f: Int) -> Intent:
    """Forward, a little right, and a jump press every 45 frames."""
    return Intent(1.0, 0.3, 0.0, 0.0, f % 45 == 10, False, False, 100.0)


def demo_console(m: DemoMode) raises -> Console:
    var con = Console()
    for s in m.console_commands():
        con.register(s.copy())
    return con^


def frame(mut m: DemoMode, mut con: Console, f: Int) raises:
    """One host frame: the replay's lines of this frame are submitted, every queued line runs, then the step."""
    con.due(f)
    for l in con.take():
        _ = m.run_command(l)
    m.step(intent_at(f), 1.0 / 60.0)


def typed_run(frames: Int, cheats: Bool) raises -> Tuple[DemoMode, String]:
    var m = DemoMode()
    var con = demo_console(m)
    for f in range(frames):
        if cheats:
            if f == 30:
                _ = con.submit("teleport 0 3 -4", f)
            if f == 40:
                _ = con.submit("god", f)
            if f == 50:
                _ = con.submit("spawn crate", f)
            if f == 120:
                _ = con.submit("noclip", f)
            if f == 160:
                _ = con.submit("noclip", f)
            if f == 170:
                _ = con.submit("cam.distance 12", f)
        frame(m, con, f)
    return (m^, con.log_text())


def main() raises:
    var c = Check()
    c.ok(CONSOLE_BUILT, "a build without -D LUDENS_RELEASE has the console")

    # --- the console on its own
    var con = Console()
    con.register(CommandSpec("echo", "word", 1, 1))
    con.register(CommandSpec("god", "", 0, 0, cheat=True))
    con.register(CommandSpec.cvar("speed", False, 5.0, 0.0, 20.0))
    con.register(CommandSpec.cvar("iters", True, 8.0, 1.0, 64.0))
    var dup = False
    try:
        con.register(CommandSpec("echo", "", 0, 0))
    except:
        dup = True
    c.ok(dup, "a name registered twice raises")
    c.ok("unknown command `fly`" in refused(con, "fly"), "an unknown command is refused: " + refused(con, "fly"))
    c.ok("usage `echo word`" in refused(con, "echo"), "a missing argument is refused with the usage")
    c.ok("usage" in refused(con, "echo a b"), "an extra argument is refused")
    c.ok("not a number" in refused(con, "speed fast"), "a cvar value that is not a number is refused")
    c.ok("outside 0.0 .. 20.0" in refused(con, "speed 21"), "a cvar value above its bound is refused: " + refused(con, "speed 21"))
    c.ok("not a whole number" in refused(con, "iters 2.5"), "an int cvar refuses 2.5")
    c.ok(len(con.take()) == 0 and con.log_text() == "", "refused lines are neither queued nor logged")
    c.ok(con.submit("speed", 0) == "speed = 5.0", "a cvar with no argument prints its value")
    c.ok("god*" in con.submit("help", 0), "help lists the commands, a cheat with a star: " + con.submit("help", 0))
    _ = con.submit("speed 7.5", 3)
    _ = con.submit("  echo   hi ", 3)
    _ = con.submit("god", 4)
    c.ok(con.value("speed") == 5.0, "a cvar keeps its value until the queue is taken")
    var taken = con.take()
    c.ok(len(taken) == 3 and taken[1].name == "echo" and taken[1].args[0] == "hi" and taken[2].cheat, "take returns the queue in order, split on spaces")
    c.ok(con.value("speed") == 7.5 and con.cheats_run == 1, "take applies the cvar and counts the cheat")
    c.ok(con.log_text() == "3 speed 7.5\n3 echo hi\n4 god\n", "the log: one `frame line` per accepted line")
    var bad = False
    try:
        con.load_replay("5 god\n4 god\n")
    except:
        bad = True
    c.ok(bad, "a replay whose frames go back raises")
    con.toggle()
    con.type_text("echo")
    con.type_text(" yo")
    con.backspace()
    con.enter(9)
    c.ok(con.open and con.lines[len(con.lines) - 1] == "> echo y" and con.log_text().endswith("9 echo y\n"), "the line editor: typed text, backspace, enter submits")
    con.type_text("nope")
    con.enter(9)
    c.ok("unknown command" in con.lines[len(con.lines) - 1], "an error is printed, not raised, from the editor")

    # --- cheats: the mark and the achievements guard
    var mark = CheatMark()
    mark.mark()
    mark.god = True
    c.ok(mark.bits() == CHEAT_MARKED | CHEAT_GOD, "god on and marked: bits 3")
    var back = CheatMark.from_bits(mark.bits())
    c.ok(back.marked and back.god and not back.noclip, "the bits read back")
    var bad_bits = False
    try:
        _ = CheatMark.from_bits(CHEAT_GOD)
    except:
        bad_bits = True
    c.ok(bad_bits, "a cheat on without the mark does not read back")
    var ach = CheatGuard[LocalAchievements](LocalAchievements())
    c.ok(ach.unlock(1, "first") == 0 and ach.is_unlocked("first"), "before a cheat an unlock goes through")
    ach.mark_cheated()
    c.ok(ach.unlock(2, "second") == REQ_CHEATED and not ach.is_unlocked("second"), "after a cheat an unlock is refused (REQ_CHEATED)")
    c.ok(ach.set_stat(3, "kills", 5) == REQ_CHEATED and ach.stat("kills") == 0 and ach.refused == 2, "and a stat too; reads still answer")

    # --- the demo game: what each cheat does
    var plain = typed_run(240, False)
    var cheat = typed_run(240, True)
    c.ok(not plain[0].cheated() and cheat[0].cheated(), "the run with cheats is marked, the other is not")
    c.ok(cheat[0].spawned == 1 and cheat[0].counters().bodies == plain[0].counters().bodies + 1, "spawn added one body (" + String(cheat[0].counters().bodies) + ")")
    c.ok(cheat[0].jumps > plain[0].jumps, "god lets the ball jump in the air: " + String(cheat[0].jumps) + " jumps against " + String(plain[0].jumps))
    c.ok(cheat[0].cam_back == 12.0, "the cvar cam.distance reached the game")
    c.ok('"cheats":' in cheat[0].state() and '"cheats":' not in plain[0].state(), "state() lists the mark only for a cheated run")
    c.ok(cheat[1].startswith("30 teleport 0 3 -4\n40 god\n50 spawn crate\n120 noclip\n160 noclip\n170 cam.distance 12\n"), "the log holds every line with its frame:\n" + cheat[1])
    # noclip: no gravity and no collisions between frame 121 and 160
    var nm = DemoMode()
    var ncon = demo_console(nm)
    _ = ncon.submit("teleport 0 1.5 3", 0)
    _ = ncon.submit("noclip", 0)
    var y0 = Real(0)
    for f in range(90):
        frame(nm, ncon, f)
        if f == 0:
            y0 = nm.world.state(nm.ball).pos[1]
    var after = nm.world.state(nm.ball).pos
    c.ok(after[1] == y0, "noclip: the height stays " + String(Float64(y0)) + " for 90 frames (now " + String(Float64(after[1])) + ")")
    var moved = sqrt((after[0] - 0.0) ** 2 + (after[2] - 3.0) ** 2)
    c.ok(moved > 5.0, "noclip: the ball still moves with the intent (" + String(Float64(moved)) + " m)")

    # --- replay: the log played into a fresh game gives the same hash
    var rm = DemoMode()
    var rcon = demo_console(rm)
    rcon.load_replay(cheat[1])
    for f in range(240):
        frame(rm, rcon, f)
    c.ok(rm.hash() == cheat[0].hash() and rm.hash() != plain[0].hash(), "the replayed log reaches the typed run's hash " + String(cheat[0].hash()) + " (without cheats: " + String(plain[0].hash()) + ")")
    c.ok(rcon.log_text() == cheat[1], "the replay logs the same lines again")

    # --- the mark is saved
    c.ok(DEMO_SAVE_VERSION == 3, "the demo save is version 3")
    var payload = cheat[0].save_state()
    var loaded = DemoMode()
    c.ok(loaded.load_state(payload) and loaded.cheated() and loaded.spawned == 1 and loaded.hash() == cheat[0].hash(), "a save made after a cheat loads marked, with the spawned crate, same hash")
    var cont_a = DemoMode()
    _ = cont_a.load_state(payload)
    var ca = demo_console(cont_a)
    var cb_m = DemoMode()
    _ = cb_m.load_state(payload)
    var cb = demo_console(cb_m)
    for f in range(240, 300):
        frame(cont_a, ca, f)
        frame(cb_m, cb, f)
    c.ok(cont_a.hash() == cb_m.hash(), "two games loaded from it go on alike")
    var noclip_save = DemoMode()
    var ns = demo_console(noclip_save)
    _ = ns.submit("noclip", 0)
    _ = ns.submit("teleport 0 1.5 3", 0)
    for f in range(20):
        frame(noclip_save, ns, f)
    var nl = DemoMode()
    _ = nl.load_state(noclip_save.save_state())
    var nlc = demo_console(nl)
    for f in range(20, 80):
        frame(noclip_save, ns, f)
        frame(nl, nlc, f)
    c.ok(nl.cheats.noclip and nl.hash() == noclip_save.hash(), "noclip survives a save and load (the ball's collision layer is set again)")
    # a version 2 payload (no mark) migrates to version 3 with the mark clear
    var v3 = plain[0].save_state()
    var v2 = List[UInt8]()
    var n = Int(v3[8])
    var at = 8 + 1 + n + 8 + 8 + 8 + 1 + 8 + 1
    for i in range(len(v3)):
        if i != at and i != at + 1:
            v2.append(v3[i])
    var mig = migrate_payload(DemoMigrator(), v2, 2, 3)
    var same = len(mig) == len(v3)
    if same:
        for i in range(len(v3)):
            if mig[i] != v3[i]:
                same = False
    c.ok(same, "2 -> 3 inserts the two cleared bytes: the result is what version 3 writes")
    # a game guarded by the mark
    var host_ach = CheatGuard[LocalAchievements](LocalAchievements())
    if loaded.cheated():
        host_ach.mark_cheated()
    c.ok(host_ach.unlock(1, "jump_10") == REQ_CHEATED, "a host that reads cheated() from the loaded game refuses its unlocks")

    # --- photo mode
    var pm = PhotoMode()
    var cam = CameraPose(Vec3(0.0, 3.2, 10.0, 0.0), Quat.from_axis_angle(Vec3(0.0, 1.0, 0.0, 0.0), 0.5), 1.0, 1.78, 0.1, 400.0)
    pm.enter(cam)
    var p0 = pm.pose()
    var f0 = p0.forward()
    var fc = cam.forward()
    c.ok(p0.position[0] == 0.0 and p0.position[1] == Real(3.2) and abs(f0[0] - fc[0]) < 1e-5 and abs(f0[2] - fc[2]) < 1e-5, "photo mode starts at the game's camera, looking the same way")
    for _ in range(600):  # 10 s forward at 4 m/s would be 40 m
        pm.move(1.0, 0.0, 0.0, 0.0, 0.0, 1.0 / 60.0)
    var d = pm.pos - pm.origin
    var dist = sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2])
    c.ok(abs(dist - pm.radius) < 1e-3 and pm.clamped > 0, "the free camera stops at the bound: " + String(Float64(dist)) + " m of " + String(Float64(pm.radius)))
    for _ in range(600):
        pm.move(0.0, 0.0, -1.0, 0.0, 0.0, 1.0 / 60.0)
    c.ok(pm.pos[1] >= pm.floor_y, "and does not go under the floor (y " + String(Float64(pm.pos[1])) + ")")
    pm.move(0.0, 0.0, 0.0, 0.0, -100000.0, 1.0 / 60.0)
    c.ok(pm.pitch <= 1.5, "pitch is limited to 1.5 rad")
    c.ok(pm.set_fstop(0.5) == 1.0 and pm.set_fstop(0) == 0.0 and pm.set_exposure(9) == 4.0 and pm.set_focus(0) == Float32(0.2), "the lens settings are clamped")
    var sz = pm.capture_size(960, 540)
    c.ok(sz[0] == 1920 and sz[1] == 1080, "the capture is twice the frame: 1920 x 1080")
    _ = pm.set_scale(8)
    var big = pm.capture_size(1920, 1080)
    c.ok(big[0] == MAX_CAPTURE_SIDE and big[1] == 4608, "a capture past 8192 is scaled down with its proportions: " + String(big[0]) + " x " + String(big[1]))
    pm.leave()
    c.ok(not pm.active, "leave")

    # --- focal length and zoom (game/zoom_lens.mojo)
    var f50 = fov_from_focal(50.0)
    c.ok(abs(Float64(f50) - 0.4710899) < 1e-6, "50 mm on a 24 mm sensor is 2 atan(0.24) = 0.4710899 rad: " + String(Float64(f50)))
    c.ok(abs(focal_from_fov(f50) - 50.0) < 1e-4, "focal_from_fov inverts it: " + String(focal_from_fov(f50)))
    var v50 = View(CameraPose(Vec3(0.0, 0.0, 0.0, 0.0), Quat.identity(), f50, 1.78, 0.1, 400.0), 1.78)
    var f_dof = 0.024 * 0.5 * Float64(v50.sy) * 1000.0  # app/lens.mojo focal_length, in mm
    c.ok(abs(f_dof - 50.0) < 1e-3, "the depth of field's focal length from that view is " + String(f_dof) + " mm")
    var zl = ZoomLens(24.0)
    _ = zl.zoom_to(96.0)
    var at_quarter = Float64(0)
    var frames = 0
    while zl.moving() and frames < 1000:
        zl.step(1.0 / 60.0)
        frames += 1
        if frames == 15:
            at_quarter = zl.focal_mm
    var want_q = 24.0 * (4.0 ** (1.0 - 0.36787944117144233))  # 63 % of the log ratio after one zoom_time (0.25 s)
    c.ok(abs(at_quarter - want_q) < 1e-6, "24 -> 96 mm at 60 Hz: " + String(at_quarter) + " mm after 0.25 s (want " + String(want_q) + ")")
    c.ok(zl.focal_mm == 96.0, "and arrives at 96 mm after " + String(frames) + " frames")
    var monotone = True
    var z2 = ZoomLens(100.0)
    _ = z2.zoom_to(20.0)
    var last = z2.focal_mm
    for _ in range(300):
        z2.step(1.0 / 60.0)
        monotone = monotone and z2.focal_mm <= last and z2.focal_mm >= 20.0
        last = z2.focal_mm
    c.ok(monotone and z2.focal_mm == 20.0, "zooming out never passes the target and ends on it: " + String(z2.focal_mm))
    var z3 = ZoomLens(50.0)
    z3.zoom_time = 0.0
    _ = z3.zoom_to(135.0)
    z3.step(1.0 / 60.0)
    c.ok(z3.focal_mm == 135.0, "zoom_time 0 jumps in one step")
    c.ok(z3.zoom_to(5000.0) == 400.0 and z3.zoom_to(0.0) == 10.0 and z3.jump_to(Float64.MAX) == 400.0, "the target is clamped to 10 .. 400 mm")

    var pz = PhotoMode()
    pz.enter(cam)
    var entry_mm = pz.lens.focal_mm
    c.ok(abs(entry_mm - focal_from_fov(1.0)) < 1e-9 and abs(Float64(pz.fov_y) - 1.0) < 1e-6, "photo mode starts at the game's field: fov 1.0 rad is " + String(entry_mm) + " mm")
    c.ok(pz.set_focal(1000.0) == Float32(PHOTO_MAX_MM) and pz.set_focal(1.0) == Float32(PHOTO_MIN_MM), "photo.focal is clamped to 12 .. 300 mm")
    _ = pz.set_focal(88.0)
    for _ in range(240):
        pz.move(0.0, 0.0, 0.0, 0.0, 0.0, 1.0 / 60.0)
    c.ok(pz.lens.focal_mm == 88.0 and abs(Float64(pz.fov_y) - Float64(fov_from_focal(88.0))) < 1e-7 and abs(Float64(pz.pose().fov_y) - Float64(pz.fov_y)) < 1e-9, "photo.focal 88 mm: after 4 s the pose's field is " + String(Float64(pz.pose().fov_y)) + " rad")
    var yaw0 = pz.yaw
    pz.move(0.0, 0.0, 0.0, 100.0, 0.0, 1.0 / 60.0)
    var turned = Float64(yaw0 - pz.yaw)
    var want_turn = 100.0 * 0.004 * Float64(pz.fov_y) / Float64(pz.enter_fov)
    c.ok(abs(turned - want_turn) < 1e-5, "at 88 mm 100 px of pointer turns " + String(turned) + " rad (" + String(want_turn) + "; 0.4 at entry)")
    var pz2 = PhotoMode()
    pz2.enter(cam)
    var held = 0
    while held < 60:  # Z held for 1 s
        pz2.zoom(1.0, 1.0 / 60.0)
        pz2.move(0.0, 0.0, 0.0, 0.0, 0.0, 1.0 / 60.0)
        held += 1
    var target_ratio = pz2.lens.target_mm / entry_mm
    c.ok(abs(target_ratio - 2.0 ** 1.5) < 1e-6, "Z held 1 s: the target is 2^1.5 = " + String(target_ratio) + " times the entry focal length")
    c.ok(pz2.lens.focal_mm > entry_mm and pz2.lens.focal_mm < pz2.lens.target_mm, "and the lens is between the two: " + String(pz2.lens.focal_mm) + " mm")
    for _ in range(600):
        pz2.zoom(-1.0, 1.0 / 60.0)
        pz2.move(0.0, 0.0, 0.0, 0.0, 0.0, 1.0 / 60.0)
    c.ok(pz2.lens.focal_mm == PHOTO_MIN_MM, "X held 10 s stops at the shortest lens, 12 mm: " + String(pz2.lens.focal_mm))

    print("console:", c.passed, "passed,", c.failed, "failed")
    if c.failed > 0:
        raise Error("console: " + String(c.failed) + " failed")
