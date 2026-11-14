# tier: integration
"""The game seam (game/mode.mojo): a host drives each game only through `GameMode`, and the wrappers change nothing.
Native only: `pixi run -e wasm test-game`.

The same frames are played twice: once through the concrete type, once through a generic host that knows only the trait.
Every number the host sees must match. Compile-time dispatch is the point: the host below is `Drive[M]`, not a trait object."""
from game.arena import Arena, DrawItem
from game.arena_mode import ArenaMode
from game.frontier import Frontier
from game.frontier_mode import FrontierMode
from game.intent import Intent
from game.mode import GameMode
from geometry.vec import Real
from procedural.camera_math import CameraPose
from ui.draw import DrawList


def intent_at(t: Int) -> Intent:
    # walk forward and turn a little, jump every 90 frames: exercises the controls, the camera and the physics
    var fwd = Real(1) if (t // 120) % 2 == 0 else Real(0)
    var jump = t % 90 == 0
    return Intent(fwd, Real(0), Real(0.5) if t % 200 < 100 else Real(-0.5), Real(0), jump, False, False)


def drive[M: GameMode](mut m: M, frames: Int) raises -> List[UInt64]:
    """Hashes after every 30th frame, plus the item count of the last scene: all a host can observe."""
    var out = List[UInt64]()
    var items = 0
    for t in range(frames):
        m.step(intent_at(t), 1.0 / 60.0)
        var scene = m.scene()
        items = len(scene)
        _ = m.cues()
        if t % 30 == 29:
            out.append(m.hash())
    out.append(UInt64(items))
    return out^


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
    comptime FRAMES = 300

    # the arena: the wrapper and the concrete type agree frame by frame
    var direct = Arena()
    var wrapped = ArenaMode()
    var hashes_direct = List[UInt64]()
    var hashes_wrapped = List[UInt64]()
    var items_direct = 0
    var items_wrapped = 0
    var cues_wrapped = 0
    for t in range(FRAMES):
        direct.update(intent_at(t), 1.0 / 60.0)
        wrapped.step(intent_at(t), 1.0 / 60.0)
        items_direct = len(direct.draw_items())
        var scene = wrapped.scene()
        items_wrapped = len(scene)
        cues_wrapped += len(wrapped.cues())
        _ = direct.take_cues()
        if t % 30 == 29:
            hashes_direct.append(direct.hash())
            hashes_wrapped.append(wrapped.hash())
    c.ok(len(hashes_direct) == 10 and hashes_direct == hashes_wrapped, "arena: the wrapper's hashes equal the concrete arena's, every 30 frames")
    c.ok(items_direct == items_wrapped and items_wrapped > 0, "arena: the scene has the same items (" + String(items_wrapped) + ")")
    c.ok(wrapped.camera().position[1] == direct.cam.position[1], "arena: the camera is the same")
    c.ok(cues_wrapped > 0, "arena: cues come through the wrapper (" + String(cues_wrapped) + " raised)")

    # the generic host, instantiated once per game: the same code path for both
    var a = ArenaMode()
    var f = FrontierMode()
    var seen_a = drive(a, 120)
    var seen_f = drive(f, 120)
    c.ok(len(seen_a) == 5 and len(seen_f) == 5, "the generic host drives both games")
    c.ok(seen_a[0] != seen_a[1] and seen_f[0] != seen_f[1], "both games change state while they run")
    c.ok(seen_a[4] > 0 and seen_f[4] > 0, "both games produce a scene")
    var hud_a = a.hud(960.0, 540.0, 2.0)
    var hud_f = f.hud(960.0, 540.0, 2.0)
    c.ok(len(hud_a.cmds) > 0 and len(hud_f.cmds) > 0, "both games produce a HUD")

    print("game_mode:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("game_mode: failed checks")
