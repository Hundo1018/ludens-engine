"""Native / wasm64 parity probe for the particle simulation (#121): the state of every particle after a fixed run, and the
bytes the particle pass uploads for it (sorted, packed), as two hashes. The run: three emitters (an additive burst, a rate
with LOD, a repeating burst against a small budget and a cap), 120 steps of 1/60 s, a camera that moves. Same functions
as game/particles.mojo; `main` prints for native, `particles_parity_run` is exported for wasm64."""
from game.particles import ParticleSystem, float_hash
from game.particles_table import particles_default_table, particles_row


def run() raises -> Tuple[UInt64, UInt64, UInt64, UInt64]:
    """(state hash, packed-record hash, live particles, drops: budget + cap + LOD) after the run."""
    var t = particles_default_table()
    var ps = ParticleSystem(900)
    _ = ps.add(particles_row(t, "spark"), 0.0, 1.0, 1.0, 7)
    var smoke = particles_row(t, "smoke")
    smoke.rate = 300.0
    _ = ps.add(smoke^, 2.0, 0.0, -1.0, 11)
    var dust = particles_row(t, "dust")
    dust.burst_count = 200
    dust.burst_every = 0.4
    dust.max_particles = 150
    _ = ps.add(dust^, -2.0, 0.0, 0.0, 13)
    for i in range(120):
        ps.step(1.0 / 60.0, Float64(i) * 0.5, 2.5, 7.0 + Float64(i) * 0.4)  # the camera walks away: the smoke's LOD kicks in
    var rec = List[Float32]()
    _ = ps.pack(119.0 * 0.5, 2.5, 7.0 + 119.0 * 0.4, 0.0, 0.0, -1.0, rec, 131072)
    return (ps.state_hash(), float_hash(rec), UInt64(ps.live_total), UInt64(ps.dropped_budget() + ps.dropped_cap() + ps.lod_skipped()))


@export
def particles_parity_run(out_ptr: UInt64) abi("C") -> Int32:
    """Writes [state hash, record hash, live, drops] to out_ptr (4 x u64). 0 = ok."""
    try:
        var r = run()
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = r[0]
        out[1] = r[1]
        out[2] = r[2]
        out[3] = r[3]
        return 0
    except e:
        print("particles_parity_run:", e)
        return -1


def main() raises:
    var r = run()
    print("state", r[0], "records", r[1], "live", r[2], "drops", r[3])
