"""Native frame breakdown for `scripts/frame_budget.py` (issue #123): the demo game's frame, segment by segment, on
native wgpu (lavapipe on a machine with no GPU).

    build/frame_budget <width> <height> <frames>

`AppOf` (app/main.mojo) cannot be built natively (its surface is an HTML canvas), so this runner does what
`AppOf._step_mode` and `AppOf._draw_mode` do, in the same order and with the same renderer, HUD and `FrameStats`, but
draws into an offscreen texture: there is no net poll and no present. It waits for the GPU after each frame, outside
the timed segments, so a queue that backs up does not leak into the next frame's numbers. Prints one line per segment
over the last FRAME_RING frames."""
from std.sys import argv
from wgpu import Instance, WGPUTextureFormat, WGPUTextureUsage
from game.camera_view import View
from game.demo_mode import DemoMode
from game.intent import Intent
from game.mode import GameMode
from geometry.vec import Real
from hud import Hud
from app.render3d import SceneRendererOf, DefaultPasses
from app.frame_stats import (
    FrameStats, now_ns, segment_name, SEGMENTS, FRAME_RING,
    SEG_STEP, SEG_PHYSICS, SEG_SCENE, SEG_PUSH, SEG_HUD, SEG_DRAW, SEG_FRAME,
)


def run[M: GameMode](width: UInt32, height: UInt32, frames: Int) raises:
    var device = Instance().request_adapter().request_device()
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(
        width, height, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="frame_budget",
    )
    var m = M.create()
    var aspect = Real(Float32(width) / Float32(height))
    var hud = Hud(device, format)
    var renderer = SceneRendererOf[DefaultPasses](device, format, View(m.camera(), aspect))
    var stats = FrameStats()
    for f in range(frames):
        stats.begin()
        var t0 = now_ns()
        var t = t0
        # D held, a jump every two seconds: the scripted input of app/game_parity.mojo, kept going
        m.step(Intent(0, 1, 0, 0, f % 120 == 10, False, False), 1.0 / 60.0)
        stats.add(SEG_PHYSICS, m.physics_ns())
        _ = m.cues()
        t = stats.lap(SEG_STEP, t)
        renderer.begin(View(m.camera(), aspect))
        t = now_ns()
        var items = m.scene()
        t = stats.lap(SEG_SCENE, t)
        for it in items:
            renderer.push(it)
        t = stats.lap(SEG_PUSH, t)
        hud.set(m.hud(Float32(width), Float32(height), 0.0), Float32(width), Float32(height))
        t = stats.lap(SEG_HUD, t)
        renderer.draw(device, target.handle().raw, width, height, hud)
        _ = stats.lap(SEG_DRAW, t)
        _ = stats.lap(SEG_FRAME, t0)
        stats.end()
        _ = device.poll(True)
    print("frame_budget", width, height, "frames", frames, "ring", min(frames, FRAME_RING), "hash", m.hash())
    for s in range(SEGMENTS):
        var r = stats.summary(s)
        print("seg", segment_name(s), "p50", r[0], "p95", r[1], "max", r[2], "count", r[3])


def main() raises:
    var args = argv()
    var w = UInt32(Int(args[1])) if len(args) > 1 else 1280
    var h = UInt32(Int(args[2])) if len(args) > 2 else 720
    var frames = Int(args[3]) if len(args) > 3 else 600
    run[DemoMode](w, h, frames)
