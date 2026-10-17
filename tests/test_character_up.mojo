# tier: integration
"""Character controller with an arbitrary up axis (ROADMAP 17.67,
`CharacterController.set_up`).

  1. Ordinary: a capsule walks 2 m/s along z for 2 s on a floor and steps
     onto a 0.2 m ledge, gravity -y. The same scene rotated 90 degrees about
     z (the floor becomes a wall at x < 0, gravity along -x, up = +x) gives
     the rotated trajectory: final positions agree within 1 mm, both end
     grounded, both on top of the ledge.
  2. Integration: the rounded-box character does the same (its box stands
     along the new up); a jump rises along up. A `Mover` (accelerating
     walk, double jump, a jump-pad `add_velocity` along up, then FLY with
     a wish along up) gives the rotated path and the same peak (1 mm).
  3. Extreme: a zero up raises; up = +y is the default (bit for bit, the
     existing character tests' output is unchanged).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from gameplay.character import CharacterController, CharacterConfig
from gameplay.movement import Mover, MoveConfig, MODEL_ACCEL, MODE_FLY
from physics.fields import WaterVolume

comptime DT: Real = 1.0 / 60.0


def _r(v: Vec3, rot: Bool) -> Vec3:
    """+y -> +x rotation (90 degrees about z, clockwise): (x, y, z) -> (y, -x, z)."""
    return Vec3(v[1], -v[0], v[2], 0) if rot else v


def _run(rot: Bool, box: Bool, jump: Bool) raises -> Tuple[Vec3, Bool, Real]:
    var sc = ContactScene6[QuatBody6]()
    var fh = _r(Vec3(20, 0.5, 20, 0), rot)
    _ = sc.add(QuatBody6.at_rest(_r(Vec3(0, -0.5, 0, 0), rot), Inertia3.box(1, 1, 1, 1)), Vec3(abs(fh[0]), abs(fh[1]), abs(fh[2]), 0), True)
    var lh = _r(Vec3(1, 0.1, 1, 0), rot)
    _ = sc.add(QuatBody6.at_rest(_r(Vec3(0, 0.1, 3, 0), rot), Inertia3.box(1, 1, 1, 1)), Vec3(abs(lh[0]), abs(lh[1]), abs(lh[2]), 0), True)
    var c = CharacterController(_r(Vec3(0, 0.92, 0, 0), rot), CharacterConfig.default(), Real(0.05) if box else Real(-1))
    if rot:
        c.set_up(Vec3(1, 0, 0, 0))
    var g = _r(Vec3(0, -9.8, 0, 0), rot)
    var top = Real(-1e9)
    for k in range(120):
        c.update(sc, Vec3(0, 0, 2, 0) if not jump else Vec3(0, 0, 0, 0), Real(4) if (jump and k == 30) else Real(0), DT, g)
        top = max(top, c.position[0] if rot else c.position[1])
    return (c.position, c.on_ground, top)


def _mover(rot: Bool) raises -> Tuple[Vec3, Real, Int]:
    """(final position, peak height along up, jumps used)."""
    var sc = ContactScene6[QuatBody6]()
    var fh = _r(Vec3(20, 0.5, 20, 0), rot)
    _ = sc.add(QuatBody6.at_rest(_r(Vec3(0, -0.5, 0, 0), rot), Inertia3.box(1, 1, 1, 1)), Vec3(abs(fh[0]), abs(fh[1]), abs(fh[2]), 0), True)
    var c = CharacterController(_r(Vec3(0, 0.92, 0, 0), rot))
    if rot:
        c.set_up(Vec3(1, 0, 0, 0))
    var cfg = MoveConfig.default()
    cfg.model = MODEL_ACCEL
    cfg.max_jumps = 2
    var m = Mover(c^, cfg)
    var g = _r(Vec3(0, -9.8, 0, 0), rot)
    var waters = List[WaterVolume]()
    var top = Real(-1e9)
    var used = 0
    for k in range(200):
        if k == 120:
            m.add_velocity(_r(Vec3(0, 6, 0, 0), rot))
        if k == 170:
            m.mode = MODE_FLY
        var wish = _r(Vec3(0, 1, 1, 0), rot) if k >= 170 else Vec3(0, 0, 2, 0)
        var press = k == 30 or k == 45
        m.update(sc, wish, press, k < 50, DT, g, waters)
        used = max(used, m.jumps)
        var p = m.cc.position
        top = max(top, p[0] if rot else p[1])
    return (m.cc.position, top, used)


def main() raises:
    var s = Suite("character_up")
    for box in [False, True]:
        var a = _run(False, box, False)
        var b = _run(True, box, False)
        var back = Vec3(-b[0][1], b[0][0], b[0][2], 0)  # inverse rotation
        var d = length(back - a[0])
        var name = String("box") if box else String("capsule")
        print("  " + name + ": up +y ends at", a[0], " up +x ends at", b[0], " (rotated back, apart", d, "m)")
        s.check(d < 1e-3 and a[1] and b[1], name + ": the rotated scene gives the rotated path, both grounded")
        s.check(a[0][1] > 1.0 and b[0][0] > 1.0, name + ": stepped onto the 0.2 m ledge (height along up > 1.0)")
    var ja = _run(False, False, True)
    var jb = _run(True, False, True)
    print("  jump at 4 m/s: peak height along up  +y", ja[2], " +x", jb[2])
    s.check(abs(ja[2] - jb[2]) < 1e-3 and ja[2] > 1.6, "a jump rises along up the same in both frames")
    var ma = _mover(False)
    var mb = _mover(True)
    var mback = Vec3(-mb[0][1], mb[0][0], mb[0][2], 0)
    print("  mover, double jump + pad + fly: +y ends at", ma[0], "peak", ma[1], "jumps", ma[2], "; +x rotated back", mback, "peak", mb[1], "jumps", mb[2])
    s.check(length(mback - ma[0]) < 1e-3 and abs(ma[1] - mb[1]) < 1e-3 and ma[2] == 2 and mb[2] == 2, "Mover: jumps, pad and fly act along up (rotated path, same peak, double jump in both)")
    var raised = False
    var c = CharacterController(Vec3(0, 1, 0, 0))
    try:
        c.set_up(Vec3(0, 0, 0, 0))
    except:
        raised = True
    s.check(raised and c.up[1] == 1, "zero up raises; the default up is +y")
    s.finish()
