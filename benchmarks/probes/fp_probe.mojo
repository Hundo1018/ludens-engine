"""Floating-point factor probe workload (ROADMAP 17.76).

Three scenes stepped 300 times - a 40-box pile, a rolling sphere on a ramp
of boxes, and a 6-box tower - then every body's position and quaternion
printed as hex f32 bits plus a 64-bit FNV hash of them. `scripts/fp_probe.py`
compiles this under different CPU targets (FMA, AVX2 / AVX-512 widths) and
optimisation levels and compares the hashes and the largest drift.
"""

from std.benchmark import keep
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6


def _bits(v: Float32) -> UInt32:
    var x = v
    return Pointer(to=x).unsafe_bitcast[UInt32]()[]


def dump(name: String, sc: ContactScene6[QuatBody6]):
    var h = UInt64(0xCBF29CE484222325)
    var line = String(name)
    for i in range(len(sc.bset.bodies)):
        var b = sc.bset.bodies[i]
        var vals: List[Float32] = [Float32(b.pos[0]), Float32(b.pos[1]), Float32(b.pos[2]), Float32(b.q.x), Float32(b.q.y), Float32(b.q.z), Float32(b.q.w)]
        for v in vals:
            var u = _bits(v)
            h ^= UInt64(u)
            h *= UInt64(0x100000001B3)
            line += " " + String(v)
    print("HASH", name, h)
    print(line)


def main():
    var g = Vec3(0, -9.8, 0, 0)
    var pile = ContactScene6[QuatBody6]()
    _ = pile.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(40):
        _ = pile.add(QuatBody6.at_rest(Vec3(Real(k % 5) * 0.6 - 1.2, 0.3 + Real(k // 5) * 0.55, Real(k % 3) * 0.1, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var roll = ContactScene6[QuatBody6]()
    _ = roll.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var ball = QuatBody6.at_rest(Vec3(0, 0.5, 0, 0), Inertia3.sphere(1, 0.5))
    ball.vel = Vec3(3, 0, 1, 0)
    _ = roll.add_sphere(ball^, 0.5, False)
    var tower = ContactScene6[QuatBody6]()
    _ = tower.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(6):
        _ = tower.add(QuatBody6.at_rest(Vec3(Real(k) * 0.02, 0.25 + Real(k) * 0.5, 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    for _ in range(300):
        pile.step_soft(1.0 / 60.0, g)
        roll.step_soft(1.0 / 60.0, g)
        tower.step_soft(1.0 / 60.0, g)
    dump("pile", pile)
    dump("roll", roll)
    dump("tower", tower)
