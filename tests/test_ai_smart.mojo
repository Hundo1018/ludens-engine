# tier: unit
"""Smart objects (ROADMAP 17.15): three NPCs take the three bench seats, the
fourth finds none; release and expiry free seats; tag filters; a disabled
object offers nothing; misuse raises."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ai.smart_objects import SmartObjects, SLOT_FREE, SLOT_RESERVED, SLOT_OCCUPIED

comptime SIT: UInt64 = 1
comptime USE: UInt64 = 2


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def main() raises:
    var s = Suite("ai_smart")
    var so = SmartObjects(reserve_ticks=100)
    var bench = so.add_object()
    var seats = List[Int]()
    for i in range(3):
        seats.append(so.add_slot(bench, _v(Real(i), 0, 0), SIT))
    var desk = so.add_object()
    var chair = so.add_slot(desk, _v(10, 0, 0), SIT | USE)

    var a = so.claim(0, SIT, _v(0, 0, -1), 0)
    var b = so.claim(1, SIT, _v(0, 0, -1), 0)
    var c = so.claim(2, SIT, _v(0, 0, -1), 0)
    s.check(a == seats[0] and b == seats[1] and c == seats[2], "nearest free seats, in claim order")
    var d = so.claim(3, SIT, _v(0, 0, -1), 0)
    s.eqi(d, chair, "fourth NPC gets the farther desk chair (also SIT)")
    var e = so.claim(4, SIT, _v(0, 0, -1), 0)
    s.eqi(e, -1, "fifth NPC: no seat left")
    so.occupy(a, 0)
    s.eqi(so.slot_state[a], SLOT_OCCUPIED, "occupied")
    so.release(a, 0)
    s.eqi(so.claim(4, SIT, _v(0, 0, -1), 1), a, "released seat goes to the waiting NPC")
    # reservation expiry
    s.eqi(so.update(50), 0, "nothing expires before the timeout")
    s.eqi(so.update(101), 4, "unoccupied reservations expire (b, c, chair, and a re-reserved at tick 1)")
    s.eqi(so.slot_state[b], SLOT_FREE, "expired slot is free")
    # tags
    s.eqi(so.claim(5, USE, _v(0, 0, 0), 200), chair, "USE only matches the desk chair")
    s.eqi(so.claim(6, USE, _v(0, 0, 0), 200), -1, "no second USE slot")
    # an agent holds one slot: a new claim releases the old one
    var first = so.claim(7, SIT, _v(2, 0, 0), 200)
    var second = so.claim(7, SIT, _v(0, 0, 0), 200)
    s.check(first != second and so.slot_state[first] == SLOT_FREE, "re-claim releases the previous slot")
    # disabled object
    so.set_enabled(bench, False)
    s.eqi(so.free_count(SIT), 0, "disabled bench offers nothing (chair taken)")
    s.eqi(so.claim(8, SIT, _v(0, 0, 0), 200), -1, "no claim on a disabled object")
    so.set_enabled(bench, True)
    s.eqi(so.free_count(SIT), 3, "re-enabled bench: all seats free again")
    # misuse
    var raised = False
    try:
        so.occupy(chair, 99)
    except:
        raised = True
    s.check(raised, "occupy by a non-holder raises")
    raised = False
    try:
        _ = so.add_slot(42, _v(0, 0, 0), SIT)
    except:
        raised = True
    s.check(raised, "slot on an unknown object raises")
    so.release_agent(5)
    s.eqi(so.slot_state[chair], SLOT_FREE, "despawned agent's slot is freed")
    s.finish()
