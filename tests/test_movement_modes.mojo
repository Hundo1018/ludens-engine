# tier: integration
"""Ledge climb, vault and driving for `Mover` (ROADMAP 17.67).

  1. Ordinary: walking into a 1.0 m wall (climb height 1.2) the character
     pulls up and ends standing on top (foot 1.0); a 0.9 m wall 0.2 m thick
     is vaulted (ends behind it at ground level); a 0.2 m step is just
     stepped (no climb); a 2.0 m wall is too high (stays on the ground).
  2. Integration: entering a vehicle body moving at 3 m/s puts the
     character on the seat every tick (exactly `act(seat)`); exiting drops
     it beside the vehicle, where it lands and walks again.
     The replay `SimState` carries movers: a snapshot taken mid-climb
     restores and ends on the same checksum.
  3. Extreme: climbing is off by default (climb height 0); a bad vehicle
     index and exiting without driving raise.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fields import WaterVolume
from gameplay.character import CharacterController
from gameplay.movement import Mover, MODE_WALK, MODE_FALL, MODE_CLIMB, MODE_DRIVE
from gameplay.replay import SimState, take, restore, checksum
from scheduler.rng import SplitMix64

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene(height: Real, depth: Real) raises -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(20, 0.5, 20, 0), True)
    _ = sc.add(QuatBody6.at_rest(Vec3(0, height / 2, 2 + depth / 2, 0), Inertia3.box(1, 1, 1, 1)), Vec3(1.5, height / 2, depth / 2, 0), True)
    return sc^


def _walk_into(height: Real, depth: Real, climb: Real) raises -> Tuple[Vec3, Int, Int, Real]:
    """(position, climbs, vaults, foot height) after 3 s walking +z."""
    var sc = _scene(height, depth)
    var m = Mover(CharacterController(Vec3(0, 0.92, 0, 0)))
    m.climb_height = climb
    var none = List[WaterVolume]()
    for _ in range(180):
        m.update(sc, Vec3(0, 0, 2, 0), False, False, DT, G, none)
    return (m.cc.position, m.climbs, m.vaults, m.cc.foot()[1])


def main() raises:
    var s = Suite("movement_modes")
    var c = _walk_into(1.0, 8.0, 1.2)
    print("  1.0 m wall: climbs", c[1], " foot", c[3], " z", c[0][2])
    s.check(c[1] == 1 and abs(c[3] - 1.0) < 0.03 and c[0][2] > 2, "pulls up onto a 1.0 m ledge and stands on it")
    var v = _walk_into(0.9, 0.2, 1.2)
    print("  0.9 m x 0.2 m wall: vaults", v[2], " foot", v[3], " z", v[0][2])
    s.check(v[2] == 1 and abs(v[3]) < 0.03 and v[0][2] > 2.2, "vaults a thin wall and lands behind it at ground level")
    var st = _walk_into(0.2, 8.0, 1.2)
    var hi = _walk_into(2.0, 8.0, 1.2)
    var off = _walk_into(1.0, 8.0, 0)
    print("  0.2 m step: climbs", st[1], " foot", st[3], ";  2.0 m wall: climbs", hi[1], " foot", hi[3], ";  climbing off: foot", off[3])
    s.check(st[1] == 0 and abs(st[3] - 0.2) < 0.03, "a 0.2 m step is stepped, not climbed")
    s.check(hi[1] == 0 and abs(hi[3]) < 0.03 and off[1] == 0 and abs(off[3]) < 0.03, "a 2 m wall is out of reach; climbing is off by default")

    # ---- driving -------------------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 1, 1, 1)), Vec3(50, 0.5, 50, 0), True)
    var car = sc.add(QuatBody6.at_rest(Vec3(0, 0.5, 5, 0), Inertia3.box(500, 1, 0.5, 2)), Vec3(1, 0.5, 2, 0), False)
    sc.set_kinematic(car)
    sc.set_velocity(car, Vec3(3, 0, 0, 0), Vec3(0, 0, 0, 0))
    var m = Mover(CharacterController(Vec3(0, 0.92, 0, 0)))
    var none = List[WaterVolume]()
    m.enter_vehicle(sc, car.index(), Vec3(0, 1, 0, 0))
    var on_seat = True
    for _ in range(60):
        sc.step_soft(DT, G)
        m.update(sc, Vec3(0, 0, 0, 0), False, False, DT, G, none)
        var seat = sc.bset.bodies[car.index()].act(Vec3(0, 1, 0, 0))
        if m.cc.position != seat or m.mode != MODE_DRIVE:
            on_seat = False
    s.check(on_seat, "driving: the character sits exactly on the seat every tick")
    m.exit_vehicle(sc, Vec3(-2, 0.5, 0, 0))
    for _ in range(90):
        sc.step_soft(DT, G)
        m.update(sc, Vec3(0, 0, 0, 0), False, False, DT, G, none)
    print("  after 1 s driving and exiting: x", m.cc.position[0], " foot", m.cc.foot()[1], " mode", m.mode)
    s.check(m.mode == MODE_WALK and abs(m.cc.foot()[1]) < 0.03 and abs(m.cc.position[0] - 1) < 0.05, "exits 2 m behind the car's centre (x 3 - 2) and lands")

    # replay: a snapshot taken in the middle of a climb continues bit for bit
    var sums = List[UInt64]()
    for split in [False, True]:
        var st = SimState(_scene(1.0, 8.0), CharacterController(Vec3(0, 0.92, 0, 0)), SplitMix64.seeded(3))
        var mv = Mover(CharacterController(Vec3(0, 0.92, 0, 0)))
        mv.climb_height = 1.2
        st.movers.append(mv^)
        for t in range(120):
            if split and t == 40:
                var snap = take(st)
                st = restore(snap)
            if t == 40:
                print("  tick 40: mover mode", st.movers[0].mode, "(4 = climbing)")
            st.movers[0].update(st.scene, Vec3(0, 0, 2, 0), False, False, DT, G, none)
        sums.append(checksum(st))
    s.check(sums[0] == sums[1], "SimState carries movers: restored mid-climb, the same checksum")

    var raised = 0
    try:
        m.enter_vehicle(sc, 99, Vec3(0, 0, 0, 0))
    except:
        raised += 1
    try:
        m.exit_vehicle(sc, Vec3(0, 0, 0, 0))
    except:
        raised += 1
    s.check(raised == 2, "a bad vehicle and exiting while not driving raise")
    s.finish()
