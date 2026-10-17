# tier: integration
"""Getting in and out of vehicles (ROADMAP 17.74, `gameplay.vehicle_seat`).

A 1.8 x 1.4 x 4 m car body on the ground; driver's door 1.2 m to its left,
exits left then right of the seat.

  1. Enter: refused 3 m from the door, accepted at 0.5 m; a second
     character is refused while the seat is taken.
  2. Ride: after the car is turned 90 deg and moved 5 m, the seat pose is
     the car pose x seat offset (1e-5).
  3. Exit: with a wall against the left side the driver gets out on the
     right; with walls on both sides the exit fails and the driver stays.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from gameplay.vehicle_seat import Seat


def car_scene(mut sc: ContactScene6[QuatBody6], wall_left: Bool, wall_right: Bool) raises -> Seat:
    var car = sc.add(QuatBody6.at_rest(Vec3(0, 0.7, 0, 0), Inertia3.box(1200, 0.9, 0.7, 2)), Vec3(0.9, 0.7, 2, 0), False)
    sc.set_kinematic(car)
    if wall_left:
        _ = sc.add(QuatBody6.at_rest(Vec3(-1.3, 1, 0, 0), Inertia3.box(1, 0.2, 1, 3)), Vec3(0.2, 1, 3, 0), True)
    if wall_right:
        _ = sc.add(QuatBody6.at_rest(Vec3(1.3, 1, 0, 0), Inertia3.box(1, 0.2, 1, 3)), Vec3(0.2, 1, 3, 0), True)
    var exits: List[Vec3] = [Vec3(-1.6, 0.2, 0.3, 0), Vec3(1.6, 0.2, 0.3, 0)]
    return Seat(car, Vec3(-0.4, 0.2, 0.3, 0), Vec3(-1.2, 0.2, 0.3, 0), 1.0, exits^)


def main() raises:
    var s = Suite("vehicle_seat")
    var scene = ContactScene6[QuatBody6]()
    var seat = car_scene(scene, False, False)
    var far = seat.try_enter(scene, 7, Vec3(-4.2, 0.9, 0.3, 0))
    var near = seat.try_enter(scene, 7, Vec3(-1.7, 0.9, 0.3, 0))
    var second = seat.try_enter(scene, 8, Vec3(-1.7, 0.9, 0.3, 0))
    s.check(not far and near and not second and seat.occupant == 7, "enter: refused far, accepted near, refused when taken")
    var q = Quat.from_axis_angle(Vec3(0, 1, 0, 0), 1.5707963)
    scene.move_to(seat.vehicle, Pose6(Vec3(0, 0.7, 5, 0), q), 1.0 / 60.0)
    scene.step(1.0 / 60.0, Vec3(0, -9.8, 0, 0), 8)
    var sp = seat.seat_pose(scene)
    var cp = scene.pose(seat.vehicle)
    var want = cp.pos + cp.rot.rotate(Vec3(-0.4, 0.2, 0.3, 0))
    print("seat after the car turned and moved:", sp.pos[0], sp.pos[1], sp.pos[2])
    s.check(length(sp.pos - want) < 1e-5, "seated pose rides with the car")
    var sc2 = ContactScene6[QuatBody6]()
    var seat2 = car_scene(sc2, True, False)
    _ = seat2.try_enter(sc2, 1, Vec3(-1.7, 0.9, 0.3, 0))
    var ex = seat2.try_exit(sc2)
    print("wall on the left: exit ok", ex[0], " at x", ex[1][0])
    s.check(ex[0] and ex[1][0] > 1 and seat2.free(), "left blocked: out on the right")
    var sc3 = ContactScene6[QuatBody6]()
    var seat3 = car_scene(sc3, True, True)
    _ = seat3.try_enter(sc3, 1, Vec3(-1.0, 0.9, 0.3, 0))
    var ex3 = seat3.try_exit(sc3)
    s.check(not ex3[0] and seat3.occupant == 1, "both sides blocked: stays seated")
    var raised = False
    try:
        _ = Seat(seat3.vehicle, Vec3(0, 0, 0, 0), Vec3(0, 0, 0, 0), 1.0, List[Vec3]())
    except:
        raised = True
    s.check(raised, "a seat without exits raises")
    s.finish()
