"""The controls (game/controls.mojo): held keys become movement, edges become one-shot actions, the camera turns
only while the left button is held, and the pointer's first jump is not a turn. Native only: `pixi run -e wasm test-game`."""
from game.controls import Controls, Keys


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


def main() raises:
    var c = Check()
    var ctl = Controls()

    var k = Keys()
    k.up = True
    k.right = True
    var i = ctl.poll(k)
    c.ok(i.forward == 1 and i.right == 1 and not i.jump, "W + D: forward and right")

    k.down = True
    k.left = True
    i = ctl.poll(k)
    c.ok(i.forward == 0 and i.right == 0, "opposite keys cancel")

    var e = Keys()
    e.jump = True
    e.pause = True
    e.restart = True
    i = ctl.poll(e)
    c.ok(i.jump and i.pause and i.restart, "edges pass through")
    i = ctl.poll(Keys())
    c.ok(not i.jump and not i.pause and not i.restart, "an edge lasts one frame because Keys is rebuilt each frame")

    # the first pointer event is a jump from (0, 0): no turn, even with the button held
    var look = Controls()
    var m = Keys()
    m.look_held = True
    m.mouse_dx = 640
    m.mouse_dy = 360
    i = look.poll(m)
    c.ok(i.look_dx == 0 and i.look_dy == 0, "the first pointer jump is not a camera turn")
    m.mouse_dx = 12
    m.mouse_dy = -4
    i = look.poll(m)
    c.ok(i.look_dx == 12 and i.look_dy == -4, "after that, a drag with the button held turns the camera")
    m.look_held = False
    i = look.poll(m)
    c.ok(i.look_dx == 0 and i.look_dy == 0, "moving the pointer without the button does not turn it")

    print("arena_controls:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("arena_controls: " + String(c.failed) + " checks failed")
