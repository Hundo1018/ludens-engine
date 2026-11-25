"""Native frame breakdown for `scripts/frame_budget.py` and `scripts/perf_gate.py` (issue #123): the demo game's frame,
segment by segment, on native wgpu (lavapipe on a machine with no GPU).

    build/frame_budget <width> <height> <frames> [scene] [seed] [ring]

`scene` and `seed` are `GameMode.reset`'s (the scripted scene of docs/automation.md; default: the game's own start). With
`ring` the last FRAME_RING frames are printed raw, one `frame` line each, for scripts/frame_trace.py.
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
from hud import Hud, refresh_hud
from app.render3d import SceneRendererOf, DefaultPasses
from app.frame_stats import (
    FrameStats, now_ns, segment_name, SEGMENTS, FRAME_RING,
    SEG_STEP, SEG_PHYSICS, SEG_AI, SEG_SCENE, SEG_PUSH, SEG_HUD, SEG_DRAW, SEG_FRAME,
    SEG_GPU_SHADOW, SEG_GPU_SCENE, SEG_GPU_POST, SEG_GPU_FRAME,
    CTR_DRAWS, CTR_TRIANGLES, CTR_TEXTURE_BYTES, CTR_PARTICLES, CTR_BODIES, CTR_AI_AGENTS,
    COUNTERS, counter_name,
)
from app.gpu_timer import gpu_timer_features
from wgpu.adapter import Adapter
from wgpu.device import Device


def make_device(adapter: Adapter) raises -> Device:
    """With the timestamp features when the adapter has them, else without (the frame then has no GPU rows)."""
    try:
        return adapter.request_device(required_features=gpu_timer_features())
    except e:
        return adapter.request_device()


def run[M: GameMode](width: UInt32, height: UInt32, frames: Int, scene: String, seed: UInt64, ring: Bool) raises:
    var device = make_device(Instance().request_adapter())
    var format = WGPUTextureFormat.RGBA8Unorm
    var target = device.create_texture(
        width, height, 1, format, WGPUTextureUsage.RENDER_ATTACHMENT | WGPUTextureUsage.COPY_SRC, label="frame_budget",
    )
    var m = M.create()
    if scene.byte_length() > 0 or seed != 0:
        if not m.reset(seed, scene):
            raise Error("frame_budget: this game has no seeds or scenes")
    var aspect = Real(Float32(width) / Float32(height))
    var hud = Hud(device, format)
    var renderer = SceneRendererOf[DefaultPasses](device, format, View(m.camera(), aspect))
    var stats = FrameStats()
    var gpu = renderer.enable_gpu_timing(device)
    for f in range(frames):
        stats.begin()
        var t0 = now_ns()
        var t = t0
        # D held, a jump every two seconds: the scripted input of app/game_parity.mojo, kept going
        m.step(Intent(0, 1, 0, 0, f % 120 == 10, False, False), 1.0 / 60.0)
        stats.add(SEG_PHYSICS, m.physics_ns())
        stats.add(SEG_AI, m.ai_ns())
        var gc = m.counters()
        stats.set_counter(CTR_PARTICLES, gc.particles)
        stats.set_counter(CTR_BODIES, gc.bodies)
        stats.set_counter(CTR_AI_AGENTS, gc.ai_agents)
        _ = m.cues()
        t = stats.lap(SEG_STEP, t)
        renderer.begin(View(m.camera(), aspect))
        t = now_ns()
        var items = m.scene()
        t = stats.lap(SEG_SCENE, t)
        for it in items:
            renderer.push(it)
        t = stats.lap(SEG_PUSH, t)
        refresh_hud(hud, m, Float32(width), Float32(height), 0.0)
        t = stats.lap(SEG_HUD, t)
        renderer.draw(device, target.handle().raw, width, height, hud)
        hud.uploaded()
        _ = stats.lap(SEG_DRAW, t)
        _ = stats.lap(SEG_FRAME, t0)
        stats.set_counter(CTR_DRAWS, renderer.counts.draws)
        stats.set_counter(CTR_TRIANGLES, renderer.counts.triangles)
        stats.set_counter(CTR_TEXTURE_BYTES, renderer.tex_bytes)
        _ = device.poll(True)  # outside the timed segments
        if gpu:
            var g = renderer.gpu_times()
            stats.add(SEG_GPU_SHADOW, g[0])
            stats.add(SEG_GPU_SCENE, g[1])
            stats.add(SEG_GPU_POST, g[2])
            stats.add(SEG_GPU_FRAME, g[3])
        stats.end()
    print("frame_budget", width, height, "frames", frames, "ring", min(frames, FRAME_RING), "hash", m.hash(), "gpu_timing", gpu)
    for s in range(SEGMENTS):
        var r = stats.summary(s)
        print("seg", segment_name(s), "avg", r[0], "p50", r[1], "p95", r[2], "p99", r[3], "max", r[4], "count", r[5])
    for c in range(COUNTERS):
        var r = stats.counter_summary(c)
        print("ctr", counter_name(c), "last", r[0], "avg", r[1], "max", r[2])
    if ring:
        for k in range(stats.filled):
            var line = String("frame ") + String(k)
            for s in range(SEGMENTS):
                line += " " + String(stats.frame_ns(k, s))
            for c in range(COUNTERS):
                line += " " + String(stats.ctr_ring[stats._slot(k) * COUNTERS + c])
            print(line)


def main() raises:
    var args = argv()
    var w = UInt32(Int(args[1])) if len(args) > 1 else 1280
    var h = UInt32(Int(args[2])) if len(args) > 2 else 720
    var frames = Int(args[3]) if len(args) > 3 else 600
    var scene = String(args[4]) if len(args) > 4 else String()
    var seed = UInt64(Int(args[5])) if len(args) > 5 else UInt64(0)
    var ring = len(args) > 6 and String(args[6]) == "ring"
    run[DemoMode](w, h, frames, scene, seed, ring)
