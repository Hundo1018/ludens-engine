"""B3 bench: per-frame cost of the shell's CPU work for n bodies, on wasm64 and native from one source.

A frame is what app_frame does before the GPU: step the world, then gather every body's pose into the
contiguous f32 staging array that goes to wgpuQueueWriteBuffer by pointer (12 floats per body)."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3
from scheduler.build_opts import SERIAL_ONLY
from std.time import perf_counter_ns


def _build(n: Int) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(400.0, 1.0, 400.0, 0.0), 0.0, True)
    # One layer on the floor: every body is in contact from the first frame, so the per-body load is the
    # same at every n (stacked layers would leave most bodies in free fall during the measured frames).
    var side = 1
    while side * side < n:
        side += 1
    var half = Real(side) * 0.6
    for i in range(n):
        var x = Real(i % side) * 1.2 - half
        var z = Real(i // side) * 1.2 - half
        _ = w.add_box(Vec3(x, 0.55, z, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
    return w^


def _median(mut v: List[UInt64]) -> UInt64:
    for i in range(1, len(v)):  # insertion sort: at most a few dozen samples
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v[len(v) // 2]


def run(n: Int, frames: Int) raises -> Tuple[UInt64, UInt64, UInt64]:
    """(median physics ns, median pose-gather ns, fnv1a of the last staging array) per frame.
    Two warm-up frames in the same world are run first and not counted."""
    var w = _build(n)
    var handles = w.bodies()
    var staging = List[Float32](length=12 * len(handles), fill=0.0)
    var physics = List[UInt64]()
    var gather = List[UInt64]()
    for f in range(frames + 2):
        var t0 = perf_counter_ns()
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()
        var t1 = perf_counter_ns()
        for i in range(len(handles)):
            var st = w.state(handles[i])
            var o = 12 * i
            staging[o] = Float32(st.pos[0]); staging[o + 1] = Float32(st.pos[1]); staging[o + 2] = Float32(st.pos[2])
            staging[o + 4] = Float32(st.rot.x); staging[o + 5] = Float32(st.rot.y)
            staging[o + 6] = Float32(st.rot.z); staging[o + 7] = Float32(st.rot.w)
        var t2 = perf_counter_ns()
        if f >= 2:
            physics.append(UInt64(t1 - t0))
            gather.append(UInt64(t2 - t1))
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(staging)):
        h = (h ^ UInt64(staging[i].to_bits())) * UInt64(0x100000001B3)
    return (_median(physics), _median(gather), h)


@export
def bench_run(n: Int32, frames: Int32, out_ptr: UInt64) abi("C") -> Int32:
    """Writes [median physics ns, median gather ns, pose hash] to out_ptr (3 x u64). 0 = ok."""
    try:
        var r = run(Int(n), Int(frames))
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = r[0]; out[1] = r[1]; out[2] = r[2]
        return 0
    except e:
        print("bench_run:", e)
        return -1


def main() raises:
    print("serial_only", SERIAL_ONLY)
    for n in [1000, 10000]:
        var frames = 30 if n == 1000 else 10
        var r = run(n, frames)
        print("n", n, "frames", frames, "physics_ms", Float64(r[0]) / 1e6,
              "gather_ms", Float64(r[1]) / 1e6, "hash", r[2])
