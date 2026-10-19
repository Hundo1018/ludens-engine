"""A wheeled `Vehicle` as one `ForceElement` (ROADMAP 17.74).

`Vehicle.update` (17.4) is the whole wheeled pipeline: steering, drivetrain,
aerodynamics, wheel probes, suspension, tyres. Wrapping it as an element lets
a chassis carry it next to other elements (a rocket `Thruster`, a `Wing`, a
`HullBuoyancy` for an amphibious car): `apply` runs one `update` with the
stored `input` and `dt`, and the other elements add their forces in the same
step. The vehicle applies its forces itself (impulses at the wheels and the
aero drag at the centre of mass), so `apply` returns zero rather than a force
it never accumulated.
"""

from geometry.vec import Real, Vec3
from physics.body_set import BodyId
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from .force_element import ForceElement
from .vehicle import Vehicle, VehicleInput
from .vehicle_wheel import WheelCast


struct VehicleElement[W: WheelCast](ForceElement, Movable):
    var vehicle: Vehicle[Self.W]
    var input: VehicleInput
    var dt: Real  # the step the scene is advanced by

    def __init__(out self, var vehicle: Vehicle[Self.W], dt: Real):
        self.vehicle = vehicle^
        self.input = VehicleInput.idle()
        self.dt = dt

    def apply(mut self, mut sc: ContactScene6[QuatBody6], id: BodyId, t: Real) raises -> Vec3:
        self.vehicle.update(sc, self.input, self.dt)
        return Vec3(0, 0, 0, 0)
