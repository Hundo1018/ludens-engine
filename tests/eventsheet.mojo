"""Event sheets (ludens-engine #24): parsing, the fixed tables of conditions and actions, bounded execution, determinism.
Native only, no GPU. `pixi run -e wasm test-editor`."""
from game.eventsheet import Sheet
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


def make(mut ball: Int64, mut crate: Int64) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = w.add_box(Vec3(0.0, -10.0, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), 0.0, True)
    ball = w.add_sphere(Vec3(0.0, 2.0, 0.0, 0.0), 0.3, 1.0, False)
    crate = w.add_box(Vec3(3.0, 5.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 1.0, False)
    return w^


def run(mut sheet: Sheet, mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        sheet.step(w)
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()


def parse_fails(text: String, needle: String) -> Bool:
    try:
        _ = Sheet.parse(text)
    except e:
        return needle in String(e)
    return False


def main() raises:
    var c = Check()
    var ball: Int64 = 0
    var crate: Int64 = 0

    # a small game: count seconds, score when the ball falls through y = 0, then remove it
    var game = String("event 1\\n  when tick_mod 60\\n  do add seconds 1\\n")
    game = String(
        "# count every 60th tick; score once when the ball drops below y = 0.5, then remove it\n"
        "event 1\n  when tick_mod 60\n  do add seconds 1\n"
        "event 2 once\n  when below BALL 0.5\n  do add score 10\n  do emit scored\n"
        "event 3\n  when on scored\n  do remove BALL\n"
        "event 4\n  when var score >= 10\n  do set done 1\n"
    )
    var w = make(ball, crate)
    var sheet = Sheet.parse(game.replace("BALL", String(ball)))
    run(sheet, w, 90)
    c.ok(sheet.get("seconds") == 2, "tick_mod 60 counted at ticks 0 and 60: seconds = 2")
    c.ok(sheet.get("score") == 10, "the 'once' event scored exactly once")
    c.ok(not w.is_alive(ball), "a signal in the same tick removed the ball (event 3 after event 2)")
    c.ok(sheet.get("done") == 1, "a variable comparison saw the new score")

    # parent: runs only in a tick where the parent held
    var w2 = make(ball, crate)
    var sh2 = Sheet.parse("event 1\n  when tick_mod 10\nevent 2 parent 1\n  do add child 1\nevent 3\n  do add always 1\n")
    run(sh2, w2, 100)
    c.ok(sh2.get("child") == 10 and sh2.get("always") == 100, "a child runs only when its parent's conditions held (10 of 100 ticks), an event without conditions every tick")

    # exists, velocity, impulse
    var w3 = make(ball, crate)
    var sh3 = Sheet.parse("event 1 once\n  when exists " + String(crate) + "\n  do velocity " + String(crate) + " 0 8 0\nevent 2 once\n  when tick_mod 5\n  do impulse " + String(ball) + " 0 3 0\n")
    var y0 = w3.state(crate).pos[1]
    run(sh3, w3, 30)
    c.ok(w3.state(crate).pos[1] > y0, "set velocity (0, 8, 0) lifted the crate above its start")
    c.ok(w3.state(ball).vel[1] > -9.81 * 0.5 + 2.0, "an impulse of +3 m/s gave the ball an upward kick")

    # an adversarial chain is cut at once and counted, it cannot loop
    var w4 = make(ball, crate)
    var sh4 = Sheet.parse("event 1\n  do emit b\nevent 2\n  when on b\n  do emit a\nevent 3\n  when on a\n  do emit b\n")
    run(sh4, w4, 50)
    c.ok(sh4.cut == 50, "E1 -> E2 -> E3 -> (E1 again) is cut once per tick: 50 ticks, 50 cuts (" + String(sh4.cut) + ")")

    # determinism: the same sheet and world twice give the same hash and variables; the sheet really acts
    var wa = make(ball, crate)
    var wb = make(ball, crate)
    var wc = make(ball, crate)
    var text = "event 1\n  when tick_mod 20\n  do impulse " + String(crate) + " 0 2 0\n  do add n 1\n"
    var sa = Sheet.parse(text)
    var sb = Sheet.parse(text)
    run(sa, wa, 200)
    run(sb, wb, 200)
    var nosheet = Sheet.parse("")
    run(nosheet, wc, 200)
    c.ok(wa.hash() == wb.hash() and sa.get("n") == sb.get("n") and sa.get("n") == 10, "same sheet, same world: same hash and variables")
    c.ok(wa.hash() != wc.hash(), "control: without the sheet the world ends differently")

    # actions on a body that is gone do nothing
    var w5 = make(ball, crate)
    var sh5 = Sheet.parse("event 1 once\n  do remove " + String(crate) + "\nevent 2\n  do velocity " + String(crate) + " 0 1 0\n  do impulse " + String(crate) + " 0 1 0\n  do add ticks 1\n")
    run(sh5, w5, 5)
    c.ok(not w5.is_alive(crate) and sh5.get("ticks") == 5, "velocity and impulse on a removed body do nothing and the sheet keeps running")

    # input conditions: held vs went down; the sheet reads only the table the host fills
    var w6 = make(ball, crate)
    var sh6 = Sheet.parse("event 1\n  when key fire\n  do add held 1\nevent 2\n  when pressed fire\n  do add edges 1\n")
    sh6.step(w6)
    sh6.set_input("fire", True)
    sh6.step(w6)
    sh6.step(w6)
    sh6.set_input("fire", False)
    sh6.step(w6)
    sh6.set_input("fire", True)
    sh6.step(w6)
    c.ok(sh6.get("held") == 3 and sh6.get("edges") == 2, "key held for 3 ticks, pressed fired on 2 down-edges (held " + String(sh6.get("held")) + ", edges " + String(sh6.get("edges")) + ")")
    var sh6b = Sheet.parse("event 1\n  when key never_reported\n  do add x 1\n")
    run(sh6b, w6, 5)
    c.ok(sh6b.get("x") == 0, "an input the host never reported is not down")

    # spawn actions: handle goes into a variable; the new body is alive and falls; capped
    var w7 = make(ball, crate)
    var sh7 = Sheet.parse("event 1 once\n  do spawn_box b 5 8 0 0.2 0.2 0.2 1\n  do spawn_sphere s -5 8 0 0.25 1\n")
    run(sh7, w7, 30)
    var hb = Int64(sh7.get("b"))
    var hs = Int64(sh7.get("s"))
    c.ok(hb != hs and w7.is_alive(hb) and w7.is_alive(hs) and w7.state(hb).pos[1] < 8.0 and w7.state(hs).pos[1] < 8.0 and w7.state(hb).pos[0] == 5.0, "spawn_box and spawn_sphere add bodies whose handles are in b and s, and they fall")
    var sh8 = Sheet.parse("event 1\n  do spawn_sphere s 0 50 0 0.1 1\n")
    var w8 = make(ball, crate)
    for _ in range(1010):
        sh8.step(w8)
    c.ok(sh8.spawned == 1000 and sh8.spawn_cut == 10, "spawns stop at 1000 per sheet, the 10 more are counted (" + String(sh8.spawned) + ", " + String(sh8.spawn_cut) + ")")
    c.ok(parse_fails("event 1\n  do spawn_box b 0 0 0 0 1 1 1\n", "must be > 0") and parse_fails("event 1\n  do spawn_sphere s 0 0 0 1\n", "needs"), "bad spawn arguments are refused with the event named")

    # touching: a box dropped 1.1 m lands at about tick 28 (free fall sqrt(2 * 1.1 / 9.81) = 0.47 s), then rests
    var wt = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    var ground = wt.add_box(Vec3(0.0, -10.0, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), 0.0, True)
    var box = wt.add_box(Vec3(0.0, -8.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 1.0, False)
    var far = wt.add_box(Vec3(10.0, -8.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 1.0, False)
    var tsrc = String(
        "event 1 once\n  when touching BOX GROUND\n  do set landed 1\n"
        "event 2\n  when touching GROUND BOX\n  do add contact_ticks 1\n"
        "event 3\n  when touching BOX FAR\n  do add wrong 1\n"
    )
    var tsheet = Sheet.parse(tsrc.replace("BOX", String(box)).replace("GROUND", String(ground)).replace("FAR", String(far)))
    run(tsheet, wt, 10)
    c.ok(tsheet.get("landed") == 0 and tsheet.get("contact_ticks") == 0, "no contact while the box is still falling (tick 10)")
    run(tsheet, wt, 80)
    var ct = tsheet.get("contact_ticks")
    c.ok(tsheet.get("landed") == 1, "touching box ground held once the box landed")
    c.ok(ct > 50 and ct < 70, "touching ground box (other order) held on every tick after landing at about tick 28: " + String(ct) + " of 90")
    c.ok(tsheet.get("wrong") == 0, "two bodies that never meet are never touching")
    c.ok(parse_fails("event 1\n  when touching 3\n", "two body handles") and parse_fails("event 1\n  when touching 3 3\n", "two different"), "touching needs two different handles")

    # errors name the line and the event
    c.ok(parse_fails("event 1\n  when sometimes\n", "line 2") and parse_fails("event 1\n  when sometimes\n", "event 1"), "unknown condition: line and event named")
    c.ok(parse_fails("event 1\n  do explode 3\n", "unknown action `explode`"), "unknown action named")
    c.ok(parse_fails("event 1\n  do velocity 3 0 x 0\n", "must be a number"), "a bad number is reported")
    c.ok(parse_fails("event 1\n  when var a ?? 3\n", "unknown comparison"), "unknown comparison operator")
    c.ok(parse_fails("event 1\nevent 1\n", "defined twice"), "duplicate event id")
    c.ok(parse_fails("event 2 parent 5\n", "does not exist"), "parent that does not exist")
    c.ok(parse_fails("when tick_mod 3\n", "before any `event`"), "a condition before any event")
    c.ok(parse_fails("event 1\n  when tick_mod 0\n", "divisor"), "tick_mod 0")
    c.ok(parse_fails("garbage\n", "unknown line start"), "a line that starts with nothing known")

    print("eventsheet:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("eventsheet: " + String(c.failed) + " checks failed")
