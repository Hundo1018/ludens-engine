# tier: integration
"""The in-game console, the cheats and photo mode (issue #146; docs/console.md): what the console accepts and refuses,
that a log played back reaches the same hash as the run that typed it, what each cheat does in the demo game, that the
cheat mark is saved and refuses achievements, and photo mode's bound, settings and capture size. Native only:
`pixi run -e wasm test-console` (scripts/test_console.py also builds the release variant, tests/console_release.mojo)."""
from game.cheats import CHEAT_GOD, CHEAT_MARKED, CheatMark
from game.console import CONSOLE_BUILT, CommandSpec, Console, ConsoleLine
from game.demo_mode import DEMO_SAVE_VERSION, DemoMigrator, DemoMode
from game.intent import Intent
from game.mode import GameMode
from game.photo_camera import MAX_CAPTURE_SIDE, PhotoMode
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

    print("console:", c.passed, "passed,", c.failed, "failed")
    if c.failed > 0:
        raise Error("console: " + String(c.failed) + " failed")
