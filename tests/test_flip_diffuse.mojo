# tier: integration
"""Spray, foam and bubbles on the FLIP water (ROADMAP 17.60,
`physics.flip_diffuse.DiffuseParticles`).

  1. Ordinary: still water (1 m tank, 0.3 m deep, 1 s) spawns nothing; a
     0.25 x 0.5 m dam break spawns diffuse particles where it moves (936 in
     1 s, 788 alive: 781 bubbles, 7 foam, no spray yet -- the front stays a
     dense sheet on this 2.5 cm grid; printed every 0.2 s), all inside the
     box, and the same seed gives the same particles bit for bit.
  2. Integration: a spray particle far from the water is ballistic: after
     0.1 s its vertical velocity is -g t and its horizontal one unchanged
     (1e-5).
  3. Extreme: the cap (`max_particles`) bounds the live particles.
"""

from harness.runner import Suite
from geometry.vec import Real
from physics.flip import FlipWater2
from physics.flip_diffuse import DiffuseParticles, SPRAY, FOAM, BUBBLE


def dam(seed: UInt64, cap: Int = 100000) raises -> DiffuseParticles:
    var d = FlipWater2(80, 24, 0.025)
    d.fill_box(0, 0, 0.25, 0.5)
    var df = DiffuseParticles(seed, cap)
    for k in range(250):
        d.step(0.004)
        df.update(d, 0.004)
        if k % 50 == 49:
            print("  t", Real(k + 1) * 0.004, "diffuse", df.count(), " spray", df.count_kind(SPRAY), " foam", df.count_kind(FOAM), " bubble", df.count_kind(BUBBLE), " spawned", df.spawned)
    return df^


def main() raises:
    var s = Suite("flip_diffuse")
    var w = FlipWater2(40, 24, 0.025)
    w.fill_box(0, 0, 1.0, 0.3)
    var ds = DiffuseParticles(1)
    var t = Real(0)
    while t < 1.0:
        var dt = min(Real(0.005), w.max_dt())
        w.step(dt)
        ds.update(w, dt)
        t += dt
    print("still tank 1 s: spawned", ds.spawned)
    s.check(ds.spawned == 0, "still water spawns nothing")

    var a = dam(7)
    var b = dam(7)
    var inside = True
    var same = a.count() == b.count() and a.spawned == b.spawned
    for k in range(a.count()):
        inside = inside and a.x[k] >= 0 and a.x[k] <= 2.0 and a.y[k] >= 0 and a.y[k] <= 0.6
        if k < b.count():
            same = same and a.x[k] == b.x[k] and a.y[k] == b.y[k]
    print("dam break 1 s: spawned", a.spawned, " alive", a.count())
    s.check(a.spawned > 0 and a.count() > 0 and inside and same, "the dam break spawns diffuse particles, inside the box, reproducibly")

    var e = FlipWater2(8, 8, 0.1, 9.8)
    var sp = DiffuseParticles(3)
    sp.x.append(0.2)
    sp.y.append(0.7)
    sp.u.append(1.0)
    sp.v.append(0.0)
    sp.age.append(0)
    sp.kind.append(SPRAY)
    for _ in range(10):
        sp.update(e, 0.01)
    print("lone spray after 0.1 s: u", sp.u[0], " v", sp.v[0], " (-g t", -0.98, ")")
    s.check(abs(sp.v[0] + 0.98) < 1e-5 and abs(sp.u[0] - 1) < 1e-6 and sp.kind[0] == SPRAY, "spray is ballistic")

    var c = dam(7, 50)
    s.check(c.count() <= 50, "the particle cap holds (live particles; spawned counts every one ever made)")
    s.finish()
