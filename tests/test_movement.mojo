# tier: integration
"""Movement modes and velocity models (ROADMAP 17.67).

  1. Ordinary: on flat ground the direct, acceleration and Quake models all
     settle at the 3 m/s wish speed (parity), and the acceleration model
     covers less ground on the way (transient); a jump pressed 3 ticks after
     walking off a ledge still jumps (coyote 6), 12 ticks after does not; a
     press 4 ticks before landing jumps on landing and one 10 ticks before
     does not (buffer 6); a released
     jump peaks lower than a held one; with max_jumps 2 a second jump works
     in the air and a third does not.
  2. Integration: walking into a pool switches to SWIM and out of it back
     to WALK; bobbing at the surface changes mode at most twice with
     hysteresis (0.6 / 0.4) and more often without it (0.5 / 0.5) when
     waves hold it at 50 % +- 6 % submerged;
     knockback along z while walking along x keeps the walk speed and adds
     the push; a character on a platform turning at 1 rad/s gains 1 rad of
     heading per second; a copy of the mover plus a scene snapshot continue
     bit for bit.
  3. Extreme: `dt = 0` changes nothing; a NaN wish is treated as no wish.
"""

from std.math import isfinite
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from physics.serialize import scene_to_bytes, scene_from_bytes
from gameplay.character import CharacterController
from gameplay.movement import (
    Mover, MoveConfig, MODEL_DIRECT, MODEL_ACCEL, MODEL_QUAKE,
    MODE_WALK, MODE_FALL, MODE_SWIM,
)

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _floor(mut sc: ContactScene6[QuatBody6], half: Real = 50, y: Real = 0):
    _ = sc.add(QuatBody6.at_rest(Vec3(0, y - 0.5, 0, 0), Inertia3.box(1, half, 0.5, half)), Vec3(half, 0.5, half, 0), True)


def _mover(model: Int, x: Real = 0, y: Real = 0.92) -> Mover:
    var cfg = MoveConfig.default()
    cfg.model = model
    return Mover(CharacterController(Vec3(x, y, 0, 0)), cfg)


def _settle(mut m: Mover, mut sc: ContactScene6[QuatBody6], ticks: Int):
    var none = List[WaterVolume]()
    for _ in range(ticks):
        m.update(sc, Vec3(0, 0, 0, 0), False, False, DT, G, none)


def _coyote(late: Int) raises -> Bool:
    var none = List[WaterVolume]()
    var sc = ContactScene6[QuatBody6]()
    _floor(sc, 1)  # a 2 m wide ledge
    var m = _mover(MODEL_DIRECT)
    _settle(m, sc, 10)
    var off = -1
    for k in range(200):
        var press = off >= 0 and k == off + late
        m.update(sc, Vec3(4, 0, 0, 0), press, press, DT, G, none)
        if off < 0 and not m.cc.on_ground:
            off = k
        if press:
            return m.cc.velocity[1] > 0
    return False


def main() raises:
    var s = Suite("movement")
    var none = List[WaterVolume]()

    # ---- velocity models -------------------------------------------------------
    var speeds = List[Real]()
    var dists = List[Real]()
    for model in [MODEL_DIRECT, MODEL_ACCEL, MODEL_QUAKE]:
        var sc = ContactScene6[QuatBody6]()
        _floor(sc)
        var m = _mover(model)
        _settle(m, sc, 10)
        var x0 = m.cc.position[0]
        for _ in range(180):
            m.update(sc, Vec3(3, 0, 0, 0), False, False, DT, G, none)
        speeds.append(m.vel[0])
        dists.append(m.cc.position[0] - x0)
    print("  3 s at a 3 m/s wish: speed direct / accel / quake", speeds[0], speeds[1], speeds[2], "  distance", dists[0], dists[1], dists[2])
    s.check(abs(speeds[0] - 3) < 1e-4 and abs(speeds[1] - 3) < 1e-4 and abs(speeds[2] - 3) < 1e-4, "all three models settle at the wish speed")
    s.check(dists[1] < dists[0] - 0.05, "the acceleration model covers less ground while speeding up")

    # ---- coyote time, buffer, variable height, double jump ------------------------
    var c3 = _coyote(3)
    var c12 = _coyote(12)
    print("  jump pressed 3 / 12 ticks after leaving the ledge: jumped", c3, c12)
    s.check(c3 and not c12, "coyote time: 3 ticks late jumps, 12 does not")

    # dry run: when does a character dropped from 1.6 m land?
    var land = -1
    var sb0 = ContactScene6[QuatBody6]()
    _floor(sb0)
    var mb0 = _mover(MODEL_DIRECT, 0, 1.6)
    for k in range(120):
        mb0.update(sb0, Vec3(0, 0, 0, 0), False, False, DT, G, none)
        if land < 0 and mb0.cc.on_ground:
            land = k
    var sb = ContactScene6[QuatBody6]()
    _floor(sb)
    var mb = _mover(MODEL_DIRECT, 0, 1.6)
    var jumped_on_landing = False
    for k in range(land + 3):
        var press = k == land - 4
        mb.update(sb, Vec3(0, 0, 0, 0), press, True, DT, G, none)
        if k >= land and mb.cc.velocity[1] > 0:
            jumped_on_landing = True
    var late = ContactScene6[QuatBody6]()
    _floor(late)
    var ml = _mover(MODEL_DIRECT, 0, 1.6)
    var jumped_late = False
    for k in range(land + 3):
        ml.update(late, Vec3(0, 0, 0, 0), k == land - 10, True, DT, G, none)
        if k >= land and ml.cc.velocity[1] > 0:
            jumped_late = True
    print("  buffer: lands at tick", land, " press 4 ticks before -> jumped", jumped_on_landing, "  10 before ->", jumped_late)
    s.check(jumped_on_landing and not jumped_late, "a press 4 ticks before landing jumps on landing, 10 ticks before does not")

    var peaks = List[Real]()
    for held in [True, False]:
        var sv = ContactScene6[QuatBody6]()
        _floor(sv)
        var mv = _mover(MODEL_DIRECT)
        _settle(mv, sv, 10)
        var top = Real(-1e9)
        for k in range(90):
            mv.update(sv, Vec3(0, 0, 0, 0), k == 0, held or k < 3, DT, G, none)
            top = max(top, mv.cc.position[1])
        peaks.append(top)
    print("  jump apex held / released after 3 ticks:", peaks[0], peaks[1])
    s.check(peaks[1] < peaks[0] - 0.2, "releasing early cuts the jump")

    var sd = ContactScene6[QuatBody6]()
    _floor(sd)
    var md = _mover(MODEL_DIRECT)
    md.cfg.max_jumps = 2
    _settle(md, sd, 10)
    var j2 = False
    var j3 = False
    for k in range(60):
        var press = k == 0 or k == 20 or k == 30
        md.update(sd, Vec3(0, 0, 0, 0), press, True, DT, G, none)
        if k == 20:
            j2 = md.cc.velocity[1] > 4
        if k == 30:
            j3 = md.cc.velocity[1] > 4
    print("  double jump: second", j2, " third", j3, " jumps used", md.jumps)
    s.check(j2 and not j3, "max_jumps 2: a second jump in the air, not a third")

    # ---- swimming and hysteresis -------------------------------------------------
    var sw = ContactScene6[QuatBody6]()
    _floor(sw, 5)  # dry ground for x < 5, the pool beyond
    _ = sw.add(QuatBody6.at_rest(Vec3(10, -3, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    var pool: List[WaterVolume] = [WaterVolume(Vec3(5, -3, -5, 0), Vec3(15, 0.3, 5, 0), 1000, 1, 1)]
    var ms = _mover(MODEL_DIRECT)
    _settle(ms, sw, 10)
    var seen_swim = False
    for _ in range(200):
        ms.update(sw, Vec3(3, 0, 0, 0), False, False, DT, G, pool)
        if ms.mode == MODE_SWIM:
            seen_swim = True
    print("  walked into a pool: swam", seen_swim, " mode now", ms.mode)
    s.check(seen_swim, "walking into deep water switches to swimming")

    var changes = List[Int]()
    for hyst in [True, False]:
        var sh = ContactScene6[QuatBody6]()
        var bob: List[WaterVolume] = [WaterVolume(Vec3(-5, -5, -5, 0), Vec3(5, 0, 5, 0), 1000, 1, 1)]
        var cfg = MoveConfig.default()
        if not hyst:
            cfg.swim_enter = 0.5
            cfg.swim_exit = 0.5
        var mh = Mover(CharacterController(Vec3(0, -0.5, 0, 0)), cfg)
        # waves: hold the body at 50 % +- 6 % submerged (height 1.8 m)
        for k in range(180):
            var ph = k % 16
            var y = Real(0.1) * (Real(ph if ph < 8 else 16 - ph) / 4 - 1)  # triangle wave, +-0.1 m
            # through a method: assigning mh.cc.position / velocity directly
            # here sent the Mojo 1.1 compiler into a loop (no result in 5 min)
            mh.cc.teleport(Vec3(0, y, 0, 0))
            mh.update(sh, Vec3(0, 0, 0, 0), False, False, DT, Vec3(0, 0, 0, 0), bob)
        changes.append(mh.mode_changes)
    print("  bobbing at 50 % +- 6 % submerged: mode changes with hysteresis", changes[0], " without", changes[1])
    s.check(changes[0] <= 1 and changes[1] > 10, "hysteresis keeps the mode from flickering")

    # ---- knockback -----------------------------------------------------------------
    var sk = ContactScene6[QuatBody6]()
    _floor(sk)
    var mk = _mover(MODEL_DIRECT)
    _settle(mk, sk, 10)
    mk.add_velocity(Vec3(0, 0, 5, 0))
    var z0 = mk.cc.position[2]
    for _ in range(60):
        mk.update(sk, Vec3(2, 0, 0, 0), False, False, DT, G, none)
    print("  knockback 5 m/s along z while walking 2 m/s along x: z moved", mk.cc.position[2] - z0, " walk speed", mk.vel[0])
    s.check(mk.cc.position[2] - z0 > 0.5 and abs(mk.vel[0] - 2) < 1e-6, "knockback adds to walking instead of being overwritten")

    # ---- rotating platform -----------------------------------------------------------
    var sp = ContactScene6[QuatBody6]()
    var plat = sp.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), False)
    sp.set_kinematic(plat)
    sp.set_velocity(plat, Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0))
    var mp = _mover(MODEL_DIRECT, 1, 0.92)
    for _ in range(60):
        sp.step_soft(DT, G)
        mp.update(sp, Vec3(0, 0, 0, 0), False, False, DT, G, none)
    print("  on a platform turning 1 rad/s for 1 s: heading", mp.heading)
    s.check(abs(mp.heading - 1) < 0.05, "heading turns with the platform")

    # ---- snapshot ---------------------------------------------------------------------
    var s1 = ContactScene6[QuatBody6]()
    _floor(s1)
    var m1 = _mover(MODEL_QUAKE)
    for k in range(40):
        m1.update(s1, Vec3(2, 0, 1, 0), k == 15, k < 25, DT, G, none)
    var s2 = scene_from_bytes(scene_to_bytes(s1))
    var m2 = m1.copy()
    var same = True
    for k in range(60):
        m1.update(s1, Vec3(1, 0, 2, 0), k == 10, k < 20, DT, G, none)
        m2.update(s2, Vec3(1, 0, 2, 0), k == 10, k < 20, DT, G, none)
        if m1.cc.position != m2.cc.position or m1.vel != m2.vel:
            same = False
    s.check(same, "mover copy + scene snapshot continue bit for bit")

    # ---- extremes -------------------------------------------------------------------------
    var se = ContactScene6[QuatBody6]()
    _floor(se)
    var me = _mover(MODEL_ACCEL)
    _settle(me, se, 10)
    var p0 = me.cc.position
    me.update(se, Vec3(3, 0, 0, 0), True, True, 0, G, none)
    s.check(me.cc.position == p0, "dt = 0 changes nothing")
    var zero = Real(0)
    me.update(se, Vec3(zero / zero, 0, 0, 0), False, False, DT, G, none)
    s.check(isfinite(me.cc.position[0]) and me.vel[0] == 0, "NaN wish counts as no wish")
    s.finish()
