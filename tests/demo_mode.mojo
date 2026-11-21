# tier: integration
"""The demo game (game/demo_mode.mojo): the same input gives the same hash, the ball moves and jumps, a jump raises its
cue once and its clip is audible, pause freezes the world, restart returns to the start. Native only:
`pixi run -e wasm test-game`."""
from game.demo_mode import DemoMode, CUE_JUMP
from game.camera_view import View
from game.intent import Intent
from geometry.vec import Real


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


def script(t: Int) -> Intent:
    return Intent(Real(1) if t < 120 else Real(0), Real(1) if t < 60 else Real(0), Real(0), Real(0), t == 30, False, False)


def run(frames: Int) raises -> DemoMode:
    var m = DemoMode()
    for t in range(frames):
        m.step(script(t), 1.0 / 60.0)
    return m^


def main() raises:
    var c = Check()
    var a = run(180)
    var b = run(180)
    c.ok(a.hash() == b.hash(), "the same input gives the same hash")
    c.ok(DemoMode().hash() != a.hash(), "the hash changes while the game runs")

    var m = DemoMode()
    var start = m.camera().position
    var cues = 0
    for t in range(180):
        m.step(script(t), 1.0 / 60.0)
        for cue in m.cues():
            if cue == CUE_JUMP:
                cues += 1
    c.ok(cues == 1 and m.jumps == 1, "one jump from one Space press (" + String(cues) + " cue, " + String(m.jumps) + " jumps)")
    c.ok(abs(m.camera().position[0] - start[0]) + abs(m.camera().position[2] - start[2]) > 1.0, "the chase camera follows the ball")
    var view = View(m.camera(), 1.78)
    var ball = m.world.state(m.ball).pos
    c.ok(view.project(ball).on_screen(), "the ball is on screen")
    c.ok(len(m.scene()) == 9, "the scene has the floor, four pillars, three crates and the ball (" + String(len(m.scene())) + ")")

    var clips = m.sounds(48000)
    var peak = Float32(0)
    for v in clips[0]:
        peak = max(peak, abs(v))
    c.ok(len(clips) == 1 and len(clips[0]) == 2 * 7680 and peak > 0.2, "one jump clip of 0.16 s, audible (peak " + String(peak) + ")")

    # an airborne ball cannot jump again
    var air = DemoMode()
    for t in range(60):
        air.step(Intent(Real(0), Real(0), Real(0), Real(0), t % 2 == 0, False, False), 1.0 / 60.0)
    c.ok(air.jumps < 30, "jumping needs the ground (" + String(air.jumps) + " jumps in 30 presses)")

    # pause freezes the world; restart returns to the start
    var p = DemoMode()
    var h0 = p.hash()
    p.step(Intent(Real(0), Real(0), Real(0), Real(0), False, True, False), 1.0 / 60.0)
    var hp = p.hash()
    for _ in range(30):
        p.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    c.ok(p.paused and p.hash() == hp and hp != h0, "paused: moving does nothing")
    p.step(Intent(Real(0), Real(0), Real(0), Real(0), False, True, False), 1.0 / 60.0)
    for _ in range(30):
        p.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    c.ok(not p.paused and p.hash() != hp, "unpaused: the world moves again")
    p.step(Intent(Real(0), Real(0), Real(0), Real(0), False, False, True), 1.0 / 60.0)
    c.ok(p.tick == 1 or p.tick == 0, "restart returns the tick count to the start")
    c.ok(len(p.hud(960.0, 540.0, 1.0).cmds) > 0, "the HUD draws")

    print("demo_mode:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("demo_mode: " + String(c.failed) + " checks failed")
