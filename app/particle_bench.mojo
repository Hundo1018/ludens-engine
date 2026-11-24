"""Frame cost of the particle simulation for n live particles, on wasm64 and native from one source (#121).

A frame is what the host does before the GPU: one `ParticleSystem.step`, then `pack` (sort the alpha particles far to near
and write the 12-float records the pass uploads). n particles of one long-lived alpha emitter, spread by a 60 degree cone
and moving (speed 0.5 to 2.5 m/s), so the sort sees mixed depths. The draw itself is measured on lavapipe in
tests/particles_native.mojo and is a CPU rasteriser's time, not a GPU's."""
from game.particles import ParticleSystem, float_hash
from game.particles_table import particles_default_table, particles_row
from std.time import perf_counter_ns


def _median(mut v: List[UInt64]) -> UInt64:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v[len(v) // 2]


def run(n: Int, frames: Int) raises -> Tuple[UInt64, UInt64, UInt64]:
    """(median step ns, median pack ns, hash of the last frame's records). Two warm-up frames are not counted."""
    var r = particles_row(particles_default_table(), "dust")
    r.rate = 0.0
    r.burst_count = n
    r.max_particles = n
    r.lifetime_min = 1000.0
    r.lifetime_max = 1000.0
    r.speed_min = 0.5
    r.speed_max = 2.5
    r.cone_deg = 60.0
    r.drag = 0.0
    r.gravity = [0.0, 0.0, 0.0]
    r.direction = [0.0, 0.0, 1.0]
    r.size_curve = [0.05]
    var ps = ParticleSystem(n)
    _ = ps.add(r^, 0.0, 1.0, 0.0, 5)
    ps.step(1.0 / 60.0, 0.0, 2.5, 7.0)
    var step_ns = List[UInt64]()
    var pack_ns = List[UInt64]()
    var rec = List[Float32]()
    for f in range(frames + 2):
        var t0 = perf_counter_ns()
        ps.step(1.0 / 60.0, 0.0, 2.5, 7.0)
        var t1 = perf_counter_ns()
        rec.clear()
        _ = ps.pack(0.0, 2.5, 7.0, 0.0, 0.0, -1.0, rec, 131072)
        var t2 = perf_counter_ns()
        if f >= 2:
            step_ns.append(UInt64(t1 - t0))
            pack_ns.append(UInt64(t2 - t1))
    return (_median(step_ns), _median(pack_ns), float_hash(rec))


@export
def particle_bench_run(n: Int32, frames: Int32, out_ptr: UInt64) abi("C") -> Int32:
    """Writes [median step ns, median pack ns, record hash] to out_ptr (3 x u64). 0 = ok."""
    try:
        var r = run(Int(n), Int(frames))
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = r[0]
        out[1] = r[1]
        out[2] = r[2]
        return 0
    except e:
        print("particle_bench_run:", e)
        return -1


def main() raises:
    for n in [1000, 10000, 100000]:
        var frames = 20 if n < 100000 else 5
        var r = run(n, frames)
        print("n", n, "frames", frames, "step_ms", Float64(r[0]) / 1e6, "pack_ms", Float64(r[1]) / 1e6, "hash", r[2])
