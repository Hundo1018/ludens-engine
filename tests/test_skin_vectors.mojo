# tier: component
"""Reference skinning vectors for a host shader (ROADMAP 17.65: "the CPU
result is the oracle of the host's GPU shader").

A fixed rig -- 6 bones (SplitMix64 seed 65, unit motors from random axis /
angle / translation), 64 vertices, K = 4 random weights (renormalised by the
skinning) -- is skinned with DLB (`skin_motor_k`) and LBS (`skin_lbs_k`).
The palette coefficients, the first 4 vertices of each method and an
FNV-1a checksum over all output bits are printed; the golden file records
them, so a change to either path's numbers shows up as a golden diff, and a
host compares its shader's output with these values (tolerance: the f32
rounding of its own arithmetic).
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.mat import Mat4
from geometry.skinning import skin_motor_k, skin_lbs_k
from scheduler.rng import SplitMix64


def fnv(mut h: UInt64, v: Vec3) -> UInt64:
    var x = h
    for a in range(3):
        x = (x ^ UInt64(v[a].to_bits())) * 0x100000001B3
    return x


def main() raises:
    var s = Suite("skin_vectors")
    var rng = SplitMix64.seeded(65)
    var bones = List[Motor3]()
    var mats = List[Mat4]()
    for _ in range(6):
        var ax = Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0)
        var l = sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2])
        var q = Quat.from_axis_angle(ax * (1 / l), Real(rng.next_f32()) * 3.0)
        var t = Vec3(Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, Real(rng.next_f32()) - 0.5, 0)
        bones.append(Motor3.from_quat_translation(q, t))
        mats.append(bones[len(bones) - 1].to_mat4())
    var rest = List[Vec3]()
    var idx = List[Int]()
    var w = List[Real]()
    for _ in range(64):
        rest.append(Vec3(Real(rng.next_f32()) * 2 - 1, Real(rng.next_f32()) * 2 - 1, Real(rng.next_f32()) * 2 - 1, 0))
        for _ in range(4):
            idx.append(Int(rng.next_f32() * 6) % 6)
            w.append(Real(rng.next_f32()))
    var dlb = List[Vec3](length=64, fill=Vec3(0, 0, 0, 0))
    var lbs = List[Vec3](length=64, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(bones, rest, idx, w, 4, dlb)
    skin_lbs_k(mats, rest, idx, w, 4, lbs)
    for b in range(2):
        var m = bones[b]
        print("palette", b, ":", m.s, m.b12, m.b13, m.b23, m.b10, m.b20, m.b30, m.pss)
    for v in range(4):
        print("v", v, "DLB", dlb[v][0], dlb[v][1], dlb[v][2], "  LBS", lbs[v][0], lbs[v][1], lbs[v][2])
    var h = UInt64(0xCBF29CE484222325)
    for v in range(64):
        h = fnv(h, dlb[v])
    var h2 = UInt64(0xCBF29CE484222325)
    for v in range(64):
        h2 = fnv(h2, lbs[v])
    print("checksum DLB", hex(h), " LBS", hex(h2))
    var finite = True
    for v in range(64):
        for a in range(3):
            finite = finite and dlb[v][a] == dlb[v][a] and lbs[v][a] == lbs[v][a]
    s.check(finite, "64 reference vertices, both methods finite")
    s.finish()
