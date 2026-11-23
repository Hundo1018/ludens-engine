# tier: unit
# Particle simulation and packing (#121), CPU only: `pixi run -e wasm test-particles`.
# Every check is against a value worked out from the emitter's own parameters (closed form, count, bound), not against
# a recorded output. The GPU pass is tests/particles_native.mojo; native against wasm64 is app/particles_parity.mojo.
from std.math import sqrt
from harness.runner import Suite
from game.particles import (
    ParticleSystem, ParticlesComponent, Emitter, particles_component, curve_at, lod_scale, cos_taylor, float_hash,
)
from game.particles_table import particles_default_table, particles_row, ParticlesRow, PARTICLES_BLEND_ADD

comptime DT = 1.0 / 60.0


def row_of(id: String) raises -> ParticlesRow:
    return particles_row(particles_default_table(), id)


def plain(burst: Int, max_particles: Int = 1000) raises -> ParticlesRow:
    """A burst of `burst` particles that start at the origin with speed 0..: gravity 0, no drag, life 10 s."""
    var r = row_of("spark")
    r.burst_count = burst
    r.rate = 0.0
    r.gravity = [0.0, 0.0, 0.0]
    r.drag = 0.0
    r.lifetime_min = 10.0
    r.lifetime_max = 10.0
    r.max_particles = max_particles
    r.blend = 0  # alpha; `spark` is additive
    return r^


def main() raises:
    var s = Suite("particles")

    # the seeded stream: the same seed gives the same state, another seed does not
    var a = ParticleSystem(100000)
    var b = ParticleSystem(100000)
    var c = ParticleSystem(100000)
    _ = a.add(row_of("spark"), 0.0, 1.0, 0.0, 7)
    _ = b.add(row_of("spark"), 0.0, 1.0, 0.0, 7)
    _ = c.add(row_of("spark"), 0.0, 1.0, 0.0, 8)
    for _ in range(30):
        a.step(DT, 0.0, 2.0, 8.0)
        b.step(DT, 0.0, 2.0, 8.0)
        c.step(DT, 0.0, 2.0, 8.0)
    print("state hash seed 7:", a.state_hash(), "seed 7 again:", b.state_hash(), "seed 8:", c.state_hash())
    s.check(a.state_hash() == b.state_hash(), "the same seed and the same steps give the same state")
    s.check(a.state_hash() != c.state_hash(), "another seed gives another state")
    s.eqi(a.live_total, 400, "spark: the burst of 400 is live after 30 steps (shortest life 0.5 s is not over)")

    # a burst is emitted once, and every particle is gone after the longest life
    var d = ParticleSystem(100000)
    _ = d.add(row_of("spark"), 0.0, 0.0, 0.0, 1)
    d.step(DT, 0.0, 0.0, 0.0)
    s.eqi(d.live_total, 400, "the burst is emitted in the first step")
    s.eqi(d.emitters[0].spawned, 400, "...and counted as spawned")
    for _ in range(80):  # 80 + 1 steps = 1.35 s > the longest life, 1.2 s
        d.step(DT, 0.0, 0.0, 0.0)
    s.eqi(d.live_total, 0, "every particle has expired after 1.35 s (life <= 1.2 s)")
    s.eqi(d.emitters[0].spawned, 400, "a burst without burst_every is not repeated")

    # burst_every repeats the burst: bursts at 0, 0.5, 1.0 s -> 3 x 100
    var rep = plain(100)
    rep.burst_every = 0.5
    var e = ParticleSystem(100000)
    _ = e.add(rep^, 0.0, 0.0, 0.0, 1)
    for _ in range(61):  # 61 steps end at t = 1.0167 s: the bursts at 0, 0.5 and 1.0 have fired
        e.step(DT, 0.0, 0.0, 0.0)
    s.eqi(e.emitters[0].spawned, 300, "burst_every 0.5 gives three bursts in 61 steps")

    # a rate: 120 / s at dt = 1/60 is 2 per step; 60 steps give 120
    var rr = plain(0)
    rr.rate = 120.0
    var f = ParticleSystem(100000)
    _ = f.add(rr^, 0.0, 0.0, 0.0, 1)
    for _ in range(60):
        f.step(DT, 0.0, 0.0, 0.0)
    s.eqi(f.emitters[0].spawned, 120, "rate 120 / s over 60 steps spawns 120")

    # the velocity cone: speed in [speed_min, speed_max], angle to the axis <= cone_deg (no gravity or drag in `plain`)
    var cone = plain(2000, 2000)
    cone.speed_min = 3.0
    cone.speed_max = 5.0
    cone.cone_deg = 35.0
    cone.direction = [0.0, 0.0, 1.0]
    var g = ParticleSystem(100000)
    _ = g.add(cone^, 0.0, 0.0, 0.0, 5)
    g.step(DT, 0.0, 0.0, 0.0)
    var cos35 = cos_taylor(35.0 * 0.017453292519943295)
    var worst_cos = 2.0
    var lo = 1e9
    var hi = 0.0
    var sum_cos = 0.0
    ref em = g.emitters[0]
    for i in range(len(em.px)):
        var sp = sqrt(em.vx[i] * em.vx[i] + em.vy[i] * em.vy[i] + em.vz[i] * em.vz[i])
        lo = min(lo, sp)
        hi = max(hi, sp)
        var cz = em.vz[i] / sp
        worst_cos = min(worst_cos, cz)
        sum_cos += cz
    print("cone: speed", lo, "to", hi, "; smallest cos(angle to axis)", worst_cos, "against cos 35 deg", cos35, "; mean cos", sum_cos / Float64(len(em.px)))
    s.check(lo >= 3.0 - 1e-9 and hi <= 5.0 + 1e-9, "speeds lie in [3, 5]")
    s.check(worst_cos >= cos35 - 1e-9, "no particle leaves the 35 degree cone")
    s.eqi(len(em.px), 2000, "2000 particles in the cone sample")
    s.check(worst_cos < cos35 + 0.02, "the cone is filled out to its edge (2000 samples)")
    # uniform over the cap's solid angle: cos is uniform in [cos35, 1], mean (1 + cos35) / 2
    s.check(abs(sum_cos / Float64(len(em.px)) - (1.0 + cos35) / 2.0) < 0.01, "directions are uniform over the cone's solid angle")
    s.check(abs(cos_taylor(1.0) - 0.5403023058681398) < 1e-12 and abs(cos_taylor(3.141592653589793) + 1.0) < 1e-9, "cos_taylor matches cos at 1 and pi")

    # gravity and drag, closed form. One particle, speed 0: after n steps v = n g dt, y = y0 + g dt^2 n (n + 1) / 2
    var grav = plain(1)
    grav.speed_min = 0.0
    grav.speed_max = 0.0
    grav.gravity = [0.0, -10.0, 0.0]
    var h = ParticleSystem(100)
    _ = h.add(grav^, 0.0, 5.0, 0.0, 1)
    for _ in range(30):
        h.step(DT, 0.0, 0.0, 0.0)
    var want_y = 5.0 - 10.0 * DT * DT * 30.0 * 31.0 / 2.0
    print("gravity: y after 30 steps", h.emitters[0].py[0], "closed form", want_y, "; vy", h.emitters[0].vy[0], "closed form", -10.0 * DT * 30.0)
    s.check(abs(h.emitters[0].py[0] - want_y) < 1e-9, "fall under gravity matches the closed form of semi-implicit Euler")
    s.check(abs(h.emitters[0].vy[0] - (-10.0 * DT * 30.0)) < 1e-9, "velocity matches n g dt")
    var drag = plain(1)
    drag.speed_min = 4.0
    drag.speed_max = 4.0
    drag.drag = 2.0
    var k = ParticleSystem(100)
    _ = k.add(drag^, 0.0, 0.0, 0.0, 1)
    k.step(DT, 0.0, 0.0, 0.0)
    var v1 = sqrt(k.emitters[0].vx[0] ** 2 + k.emitters[0].vy[0] ** 2 + k.emitters[0].vz[0] ** 2)
    for _ in range(59):
        k.step(DT, 0.0, 0.0, 0.0)
    var v60 = sqrt(k.emitters[0].vx[0] ** 2 + k.emitters[0].vy[0] ** 2 + k.emitters[0].vz[0] ** 2)
    var q = 1.0 / (1.0 + 2.0 * DT)
    var q60 = 1.0
    for _ in range(60):
        q60 *= q
    print("drag: speed after 1 step", v1, "(4 q =", 4.0 * q, ") after 60 steps", v60, "(4 q^60 =", 4.0 * q60, ")")
    s.check(abs(v1 - 4.0 * q) < 1e-9 and abs(v60 - 4.0 * q60) < 1e-9, "drag divides the speed by 1 + drag dt each step")

    # the per-emitter budget and the global cap, with the drops counted
    var bud = ParticleSystem(100000)
    _ = bud.add(plain(200, 50), 0.0, 0.0, 0.0, 1)
    bud.step(DT, 0.0, 0.0, 0.0)
    print("budget 50, burst 200: live", bud.live_total, "dropped by budget", bud.dropped_budget(), "by cap", bud.dropped_cap())
    s.eqi(bud.live_total, 50, "an emitter stops at max_particles")
    s.eqi(bud.dropped_budget(), 150, "the 150 spawns past the budget are counted")
    var cap = ParticleSystem(120)
    _ = cap.add(plain(100), 0.0, 0.0, 0.0, 1)
    _ = cap.add(plain(100), 0.0, 0.0, 0.0, 2)
    cap.step(DT, 0.0, 0.0, 0.0)
    print("global cap 120, two bursts of 100: live", cap.live_total, "dropped by cap", cap.dropped_cap(), "by budget", cap.dropped_budget())
    s.eqi(cap.live_total, 120, "the system stops at its cap")
    s.eqi(cap.dropped_cap(), 80, "the 80 spawns past the cap are counted")
    s.eqi(cap.dropped_budget(), 0, "...and not as budget drops")
    # live_total follows deaths: when particles expire the room is used again
    var tot = ParticleSystem(10)
    var short = plain(10)
    short.lifetime_min = 0.05
    short.lifetime_max = 0.05
    short.burst_every = 0.1
    _ = tot.add(short^, 0.0, 0.0, 0.0, 1)
    for _ in range(30):
        tot.step(DT, 0.0, 0.0, 0.0)
    var by_hand = 0
    for i in range(len(tot.emitters)):
        by_hand += tot.emitters[i].live()
    s.eqi(tot.live_total, by_hand, "live_total equals the particles that exist, after births and deaths")
    s.check(tot.emitters[0].spawned > 10, "freed room is used by later bursts")

    # LOD: rate 600 / s = 10 per step at full; at lod_far, lod_min 0.25 gives 2.5 per step
    var lod = plain(0)
    lod.rate = 600.0
    lod.lod_near = 20.0
    lod.lod_far = 60.0
    lod.lod_min = 0.25
    lod.max_particles = 100000
    s.check(abs(lod_scale(lod, 10.0) - 1.0) < 1e-12, "LOD scale is 1 inside lod_near")
    s.check(abs(lod_scale(lod, 40.0) - 0.625) < 1e-12, "LOD scale halfway is (1 + 0.25) / 2")
    s.check(abs(lod_scale(lod, 500.0) - 0.25) < 1e-12, "LOD scale is lod_min past lod_far")
    var near = ParticleSystem(1000000)
    var far = ParticleSystem(1000000)
    _ = near.add(lod.copy(), 0.0, 0.0, 0.0, 1)
    _ = far.add(lod.copy(), 0.0, 0.0, 0.0, 1)
    for _ in range(60):
        near.step(DT, 0.0, 0.0, 10.0)
        far.step(DT, 0.0, 0.0, 100.0)
    print("LOD, 60 steps of rate 600 / s: spawned at 10 m", near.emitters[0].spawned, "at 100 m", far.emitters[0].spawned, "; skipped", far.lod_skipped())
    s.eqi(near.emitters[0].spawned, 600, "inside lod_near the full rate spawns 600")
    s.eqi(far.emitters[0].spawned, 150, "past lod_far a quarter of the rate spawns 150")
    s.eqi(far.lod_skipped(), 450, "the 450 particles the LOD removed are counted")
    var no_lod = lod.copy()
    no_lod.lod_far = 0.0
    var nl = ParticleSystem(1000000)
    _ = nl.add(no_lod^, 0.0, 0.0, 0.0, 1)
    for _ in range(60):
        nl.step(DT, 0.0, 0.0, 500.0)
    s.eqi(nl.emitters[0].spawned, 600, "lod_far = 0 turns the LOD off at any distance")

    # curves
    var sc: List[Float64] = [0.0, 1.0, 0.5]
    s.check(curve_at(sc, 0.0) == 0.0 and curve_at(sc, 1.0) == 0.5 and abs(curve_at(sc, 0.5) - 1.0) < 1e-12 and abs(curve_at(sc, 0.25) - 0.5) < 1e-12 and abs(curve_at(sc, 0.75) - 0.75) < 1e-12, "size curve is linear between equally spaced samples")

    # packing: record fields, order, counts
    var pk = ParticleSystem(1000)
    var al = plain(0)
    al.rate = 0.0
    al.burst_count = 0
    al.size_curve = [1.0, 3.0]
    al.size_jitter = 0.0
    al.color_start = [1.0, 0.0, 0.0, 1.0]
    al.color_mid = [0.0, 1.0, 0.0, 1.0]
    al.color_end = [0.0, 0.0, 1.0, 0.0]
    al.layer = 5
    al.flipbook_cols = 4
    al.flipbook_rows = 2
    al.lifetime_min = 1.0
    al.lifetime_max = 1.0
    al.speed_min = 0.0
    al.speed_max = 0.0
    var ei = pk.add(al^, 0.0, 0.0, 0.0, 1)
    pk.emitters[ei].burst(1)
    pk.step(0.25, 0.0, 0.0, 0.0)  # age 0.25 of life 1
    var out = List[Float32]()
    var n = pk.pack(0.0, 0.0, 0.0, 0.0, 0.0, 1.0, out, 100)
    print("record at t = 0.25:", out[0], out[1], out[2], out[3], "|", out[4], out[5], out[6], out[7], "|", out[8], out[9], out[10], out[11])
    s.eqi(n[0], 1, "one alpha record")
    s.eqi(len(out), 12, "a record is 12 floats")
    s.check(abs(Float64(out[3]) - 1.5) < 1e-6, "size at t = 0.25 on [1, 3] is 1.5")
    s.check(abs(Float64(out[4]) - 0.5) < 1e-6 and abs(Float64(out[5]) - 0.5) < 1e-6 and abs(Float64(out[6])) < 1e-6 and abs(Float64(out[7]) - 1.0) < 1e-6, "colour at t = 0.25 is halfway from start (1 0 0 1) to mid (0 1 0 1)")
    s.check(out[8] == 5.0 and out[10] == 4.0 and out[11] == 2.0, "layer, columns and rows are copied")
    s.check(out[9] == 2.0, "frame at t = 0.25 of 4 x 2 cells is cell 2")

    # packing order: alpha far to near along forward (+z), additive after, in emitter order
    var po = ParticleSystem(1000)
    for zi in range(5):
        var one = plain(0)
        one.speed_min = 0.0
        one.speed_max = 0.0
        one.size_jitter = 0.0
        one.size_curve = [Float64(zi + 1)]  # the size tells which emitter a record came from
        var j = po.add(one^, 0.0, 0.0, Float64((zi * 7) % 5) * 10.0, UInt64(zi))
        po.emitters[j].burst(1)
    var ad = plain(0)
    ad.speed_min = 0.0
    ad.speed_max = 0.0
    ad.blend = PARTICLES_BLEND_ADD
    ad.size_jitter = 0.0
    ad.size_curve = [9.0]
    var aj = po.add(ad^, 0.0, 0.0, 5.0, 9)
    po.emitters[aj].burst(1)
    po.step(DT, 0.0, 0.0, -100.0)
    var rec = List[Float32]()
    var cnt = po.pack(0.0, 0.0, -100.0, 0.0, 0.0, 1.0, rec, 100)
    var sizes = List[Int]()
    for i in range(cnt[0] + cnt[1]):
        sizes.append(Int(rec[i * 12 + 3] + 0.5))
    print("pack order (sizes; z of emitter k is ((7 k) mod 5) * 10 for sizes 1..5, additive is 9):", sizes[0], sizes[1], sizes[2], sizes[3], sizes[4], sizes[5])
    # z by size: 1 -> 0, 2 -> 20, 3 -> 40, 4 -> 10, 5 -> 30; far to near = 3 (40), 5 (30), 2 (20), 4 (10), 1 (0)
    s.check(cnt[0] == 5 and cnt[1] == 1, "five alpha and one additive record")
    s.check(sizes[0] == 3 and sizes[1] == 5 and sizes[2] == 2 and sizes[3] == 4 and sizes[4] == 1 and sizes[5] == 9, "alpha records go far to near, then the additive one")
    var rec2 = List[Float32]()
    var small = po.pack(0.0, 0.0, -100.0, 0.0, 0.0, 1.0, rec2, 3)
    s.eqi(small[0] + small[1], 3, "pack stops at max_records")
    s.check(float_hash(rec) == float_hash(rec), "float_hash is a function of the bytes")

    # scene component
    var comp = particles_component("particles.rate = 30\nparticles.size_curve.0 = 0.2\nparticles.seed = 42\nparticles.cone_deg = 10\nparticles.blend = add\n")
    s.check(comp.row.rate == 30.0 and comp.seed == 42 and comp.row.blend == PARTICLES_BLEND_ADD and comp.playing, "the component's rows fill the emitter, its seed and playing")
    var bad = False
    try:
        _ = particles_component("particles.rate = 30\n")
    except err:
        print("component without size_curve:", err)
        bad = True
    s.check(bad, "a component without the required size_curve is an error")
    var bad2 = False
    try:
        _ = particles_component("particles.size_curve.0 = 0.2\nparticles.cone_deg = 200\n")
    except err:
        print("component with cone_deg 200:", err)
        bad2 = True
    s.check(bad2, "a field outside its schema range is an error")
    s.finish()
