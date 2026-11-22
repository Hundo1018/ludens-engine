"""Frame pacing probe (`scripts/frame_pacing.py`): what a fixed-step simulation looks like on displays faster than it.

Part 1, pacing. A body moves at a constant 5 m/s with no gravity and no contacts. For each (display rate, simulation
rate) the display calls `ticks_due(1 / display)` once per frame, exactly as `App.frame` and every game do today, and
records the body's x after the frame's ticks (what is drawn today, no interpolation) and the interpolated x
`prev + (cur - prev) * alpha`, `alpha = acc / dt` (what a renderer that interpolates would draw). The frame times are
exact, so this isolates the step pattern from browser timer jitter.

Part 2, cost: per-tick physics cost for n resting boxes, from `app/bench.mojo`'s `run`."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3
from scheduler.build_opts import SERIAL_ONLY
from app.bench import run

comptime SPEED: Float64 = 5.0
comptime SECONDS = 2


def pace(display_hz: Int, sim_hz: Int) raises:
    var w = EmbedWorld(1.0 / Float64(sim_hz), Vec3(0.0, 0.0, 0.0, 0.0))
    var b = w.add_sphere(Vec3(0.0, 0.0, 0.0, 0.0), 0.5, 1.0, False)
    var frames = display_hz * SECONDS
    var hist = List[Int](length=4, fill=0)
    var raw = List[Float64]()
    var lerp = List[Float64]()
    var prev = Float64(0.0)
    var cur = Float64(0.0)
    for _ in range(frames):
        var n = w.ticks_due(1.0 / Float64(display_hz))
        hist[min(n, 3)] += 1
        for _ in range(n):
            prev = cur
            w.set_velocity(b, Vec3(Real(SPEED), 0.0, 0.0, 0.0), Vec3(0.0, 0.0, 0.0, 0.0))
            w.physics_tick()
            cur = Float64(w.state(b).pos[0])
        var alpha = w.acc / w.dt
        raw.append(cur)
        lerp.append(prev + (cur - prev) * alpha)
    # per-frame on-screen step against the ideal SPEED / display_hz; skip the first second (start-up)
    var ideal = SPEED / Float64(display_hz)
    var still = 0
    var raw_max = Float64(0.0)
    var raw_min = Float64(1e9)
    var lerp_err = Float64(0.0)
    for i in range(display_hz, frames):
        var d = raw[i] - raw[i - 1]
        if d < ideal * 0.01:
            still += 1
        raw_max = max(raw_max, d)
        raw_min = min(raw_min, d)
        var e = abs((lerp[i] - lerp[i - 1]) - ideal) / ideal
        lerp_err = max(lerp_err, e)
    print("pace display", display_hz, "sim", sim_hz, "ticks0", hist[0], "ticks1", hist[1], "ticks2", hist[2],
          "ticks3+", hist[3], "still_frames", still, "of", display_hz, "raw_step_min", raw_min / ideal,
          "raw_step_max", raw_max / ideal, "lerp_err_max", lerp_err)


def main() raises:
    print("serial_only", SERIAL_ONLY)
    for d in [60, 120, 144, 165, 240]:
        for s in [60, 144]:
            pace(d, s)
    for n in [10, 50, 100, 200, 500, 1000]:
        var r = run(n, 30)
        print("cost n", n, "physics_ms", Float64(r[0]) / 1e6, "gather_ms", Float64(r[1]) / 1e6)
