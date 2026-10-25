"""Getting in and out of vehicles (ROADMAP 17.74).

A `Seat` belongs to a vehicle body: a seat pose in the body's frame, how
close a character must be to enter (`reach`, from the door point), and
exit points in the body frame tried in order. Logic only -- the caller owns
the character and decides what it does while seated (hide its capsule,
disable its controller):

  * `try_enter(sc, occupant, pos)`: succeeds when the seat is free and
    `pos` is within `reach` of the door point (world); the seat then
    records the occupant id.
  * `seat_pose(sc)`: the occupant's world pose for this tick (vehicle pose
    x seat pose), so a seated character rides along exactly.
  * `try_exit(sc)`: the first exit point whose straight path from the seat
    is clear (`ray_cast_any`, ignoring the vehicle body); frees the seat and returns the world position,
    or fails (stays seated) when every exit is blocked -- a car parked
    against a wall lets the driver out the other side, or not at all.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6, Pose6
from physics.solver6 import ContactScene6
from collision.world_query import QueryFilter


struct Seat(Copyable, Movable):
    var vehicle: BodyId
    var local_pos: Vec3
    var local_rot: Quat
    var door: Vec3  # body frame
    var reach: Real
    var exits: List[Vec3]  # body frame, tried in order
    var occupant: Int  # -1 = free

    def __init__(out self, vehicle: BodyId, local_pos: Vec3, door: Vec3, reach: Real, var exits: List[Vec3]) raises:
        if not (reach > 0) or len(exits) == 0:
            raise Error("Seat: reach > 0 and at least one exit point")
        self.vehicle = vehicle
        self.local_pos = local_pos
        self.local_rot = Quat(0, 0, 0, 1)
        self.door = door
        self.reach = reach
        self.exits = exits^
        self.occupant = -1

    def free(self) -> Bool:
        return self.occupant < 0

    def try_enter(mut self, sc: ContactScene6[QuatBody6], occupant: Int, pos: Vec3) raises -> Bool:
        if not self.free():
            return False
        var p = sc.pose(self.vehicle)
        var door = p.pos + p.rot.rotate(self.door)
        if length(pos - door) > self.reach:
            return False
        self.occupant = occupant
        return True

    def seat_pose(self, sc: ContactScene6[QuatBody6]) raises -> Pose6:
        var p = sc.pose(self.vehicle)
        return Pose6(p.pos + p.rot.rotate(self.local_pos), p.rot * self.local_rot)

    def try_exit(mut self, sc: ContactScene6[QuatBody6]) raises -> Tuple[Bool, Vec3]:
        if self.free():
            return (False, Vec3(0, 0, 0, 0))
        var p = sc.pose(self.vehicle)
        var seat = p.pos + p.rot.rotate(self.local_pos)
        var f = QueryFilter(0xFFFFFFFF, self.vehicle.index(), False)
        for e in self.exits:
            var target = p.pos + p.rot.rotate(e)
            var d = target - seat
            var l = length(d)
            if l <= 0:
                continue
            if sc.ray_cast_any(seat, d * (1 / l), l, f):
                continue
            self.occupant = -1
            return (True, target)
        return (False, Vec3(0, 0, 0, 0))
