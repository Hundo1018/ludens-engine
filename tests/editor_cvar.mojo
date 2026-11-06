"""Live tuning (ludens-shell #14): typed, range-checked variables applied at a tick boundary. Native only, no GPU.
`pixi run -e wasm test-editor`."""
from editor.cvar import CVarSet
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


def make() raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = w.add_box(Vec3(0.0, -0.5, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), 0.0, True)
    for k in range(6):
        _ = w.add_box(Vec3(0.0, Real(0.5) + Real(1.6) * Real(k), 0.0, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    return w^


def advance(mut w: EmbedWorld, n: Int) raises:
    for _ in range(n):
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()


def fails(mut cv: CVarSet, name: String, text: String, needle: String) -> Bool:
    try:
        cv.set(name, text)
    except e:
        return needle in String(e)
    return False


def main() raises:
    var c = Check()
    var cv = CVarSet()

    # a change at tick 60 equals calling set_solver before tick 60
    var wa = make()
    var wb = make()
    var wc = make()
    var it = 8
    var sub = 1
    advance(wa, 60)
    cv.set("physics.iterations", "1")
    c.ok(cv.pending() == 1 and wa.hash() == wa.hash() and cv.get("physics.iterations") == 8, "set only queues: the value and the world are untouched until apply")
    var before = wa.hash()
    cv.apply(wa, it, sub)
    c.ok(wa.hash() == before and cv.get("physics.iterations") == 1 and cv.pending() == 0, "apply changes the setting, not the world state: hash unchanged at the boundary")
    advance(wa, 120)
    advance(wb, 60)
    wb.set_solver(1, 1)
    advance(wb, 120)
    advance(wc, 180)
    c.ok(wa.hash() == wb.hash(), "set at tick 60 + apply == set_solver(1, 1) at tick 60: same hash after 180 ticks")
    c.ok(wa.hash() != wc.hash(), "control: the setting matters (a run without the change ends differently)")

    # gravity and ordering
    var wd = make()
    var we = make()
    var it2 = 8
    var sub2 = 1
    var cv2 = CVarSet()
    cv2.set("physics.gravity_y", "-3")
    cv2.set("physics.gravity_y", "-1.5")
    cv2.apply(wd, it2, sub2)
    advance(wd, 100)
    we.set_solver(8, 1)
    we.set_gravity(Vec3(0.0, -1.5, 0.0, 0.0))
    advance(we, 100)
    c.ok(wd.hash() == we.hash() and cv2.get("physics.gravity_y") == -1.5, "two sets in one boundary apply in order: the last one wins and equals set_gravity")

    # refusals
    c.ok(fails(cv, "physics.nope", "1", "unknown variable"), "unknown name")
    c.ok(fails(cv, "physics.iterations", "abc", "not a number"), "text that is not a number")
    c.ok(fails(cv, "physics.iterations", "2.5", "whole number"), "a fraction for an integer variable")
    c.ok(fails(cv, "physics.iterations", "0", "below the minimum"), "below the minimum")
    c.ok(fails(cv, "physics.iterations", "65", "above the maximum"), "above the maximum")
    c.ok(fails(cv, "physics.gravity_y", "nan", "not finite") or fails(cv, "physics.gravity_y", "nan", "not a number"), "NaN")
    c.ok(cv.pending() == 0, "every refused set left nothing queued")

    print("cvar:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("cvar: " + String(c.failed) + " checks failed")
