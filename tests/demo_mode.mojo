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
    # hud_key (the host's HUD cache, app/hud.mojo refresh_hud): unchanged while what the HUD shows is unchanged,
    # different when the jump count, the pause banner or the size changes
    var k = DemoMode()
    var k0 = k.hud_key(960.0, 540.0)
    for t in range(20):
        k.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    c.ok(k0 >= 0 and k.hud_key(960.0, 540.0) == k0, "moving without jumping keeps the HUD key")
    c.ok(k.hud_key(1280.0, 720.0) != k0, "a new size changes the HUD key")
    var jumped = False
    for t in range(60):
        k.step(Intent(Real(0), Real(0), Real(0), Real(0), t == 0, False, False), 1.0 / 60.0)
        if k.jumps > 0:
            jumped = True
    c.ok(jumped and k.hud_key(960.0, 540.0) != k0, "a jump changes the HUD key (the count is drawn)")
    var kj = k.hud_key(960.0, 540.0)
    k.step(Intent(Real(0), Real(0), Real(0), Real(0), False, True, False), 1.0 / 60.0)
    c.ok(k.paused and k.hud_key(960.0, 540.0) != kj, "pausing changes the HUD key (the banner is drawn)")

    # state(), seeds and scenes (the automation hook, docs/automation.md)
    var st = a.state()
    c.ok(st.startswith('{"tick":180,') and '"ball":{"pos":[' in st and st.endswith('"hash":"' + String(a.hash()) + '"}'), "state() is JSON with the tick, the ball and the hash: " + st)
    var s0 = DemoMode()
    c.ok(s0.reset(0, ""), "reset(0, \"\") is supported")
    for t in range(180):
        s0.step(script(t), 1.0 / 60.0)
    c.ok(s0.hash() == a.hash(), "seed 0, default scene: the hash of a run with no reset (" + String(a.hash()) + ")")
    var s1 = DemoMode()
    var s1b = DemoMode()
    var s2 = DemoMode()
    _ = s1.reset(1, "arena")
    _ = s1b.reset(1, "arena")
    _ = s2.reset(2, "arena")
    for t in range(180):
        s1.step(script(t), 1.0 / 60.0)
        s1b.step(script(t), 1.0 / 60.0)
        s2.step(script(t), 1.0 / 60.0)
    c.ok(s1.hash() == s1b.hash(), "the same seed gives the same hash")
    c.ok(s1.hash() != a.hash() and s1.hash() != s2.hash(), "different seeds give different hashes")
    var bare = DemoMode()
    _ = bare.reset(0, "bare")
    c.ok(len(bare.scene()) == 2 and '"crates":[]' in bare.state(), "scene bare: the floor and the ball, no crates")
    var bad = False
    try:
        _ = bare.reset(0, "nope")
    except:
        bad = True
    c.ok(bad, "an unknown scene raises")
    var kept = DemoMode()
    _ = kept.reset(7, "arena")
    var h7 = kept.hash()
    kept.step(Intent(Real(1), Real(0), Real(0), Real(0), False, False, False), 1.0 / 60.0)
    kept.step(Intent(Real(0), Real(0), Real(0), Real(0), False, False, True), 1.0 / 60.0)
    c.ok(kept.seed == 7 and kept.hash() != h7, "R restarts with the same seed (the tick counts one step after the restart)")

    print("demo_mode:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("demo_mode: " + String(c.failed) + " checks failed")
