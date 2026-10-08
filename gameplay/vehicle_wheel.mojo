"""Wheel-to-road contact: the seam of the raycast vehicle (ROADMAP 17.4).

A suspension needs one number per wheel per step: how far below its mounting
point the wheel hub sits when the wheel touches the road, plus the contact
point and surface normal there. `WheelCast` is that question, answered by three
interchangeable implementations that all go through `collision.world_query`:

* `RayWheel`     one ray along the suspension axis (PhysX raycast vehicle,
                 Jolt `VehicleConstraint` ray mode). Cheapest; the hub height
                 is corrected for the surface slope (`t - R / cos`), which is
                 exact for a planar road and so agrees with the sweep there.
* `SphereWheel`  a sphere of the wheel radius swept down the axis (Jolt's
                 sphere-cast mode): finds the true first touch of a rounded
                 profile, so it rolls over a kerb edge or a pothole lip where
                 the ray either misses the lip or drops into the hole.
* `CapsuleWheel` the same sweep with the wheel's width (a capsule along the
                 axle, radius = wheel radius): the tire's side edge also
                 touches.

PARITY. On a planar road (flat or sloped) all three return the same hub
distance, contact point and normal to within the query skin (`test_vehicle_wheel`).
They differ only where the surface is not planar within one wheel radius: at a
step edge the ray sees the road under the mount point only, the sweeps see the
edge up to a wheel radius ahead.

A sweep that starts already overlapping something it could not stand on (a wall
beside the wheel, normal not within ~60 degrees of the suspension axis) falls
back to the ray: a wall touching the tire neither holds the car up nor hides the
road underneath it.
"""

from geometry.vec import Real, Vec3, dot
from collision.collider_set import ColliderSet, Pose3
from collision.world_query import (
    QueryFilter,
    ray_cast,
    sphere_cast,
    capsule_cast,
)

comptime _MIN_COS: Real = 0.35  # slope cosine floor for the ray's hub correction
comptime _SUPPORT_COS: Real = 0.5  # a swept start-solid contact must face the axis


@fieldwise_init
struct WheelHit(Copyable, ImplicitlyCopyable, Movable):
    """`hub` is the distance from the suspension mount to the wheel centre
    along the suspension axis when the tire touches the road; `point` / `normal`
    describe that touch."""

    var hit: Bool
    var body: Int
    var hub: Real
    var point: Vec3
    var normal: Vec3

    @staticmethod
    def miss() -> Self:
        return Self(False, -1, 0, Vec3(0, 0, 0, 0), Vec3(0, 1, 0, 0))


trait WheelCast(Copyable, Movable, Deinitable):
    """Where does a wheel hanging from `mount` along `down` meet the road?
    `reach` is the longest suspension length of interest: a hub farther than
    that is a miss."""

    def cast(
        self,
        cs: ColliderSet,
        poses: List[Pose3],
        mount: Vec3,
        down: Vec3,
        axle: Vec3,
        reach: Real,
        radius: Real,
        half_width: Real,
        f: QueryFilter,
    ) -> WheelHit:
        ...


struct RayWheel(WheelCast):
    def __init__(out self):
        pass

    def cast(
        self,
        cs: ColliderSet,
        poses: List[Pose3],
        mount: Vec3,
        down: Vec3,
        axle: Vec3,
        reach: Real,
        radius: Real,
        half_width: Real,
        f: QueryFilter,
    ) -> WheelHit:
        var h = ray_cast(cs, poses, mount, down, reach + radius * 3, f)
        if not h.hit:
            return WheelHit.miss()
        var c = dot(h.normal, -down)
        if c < _MIN_COS:
            c = _MIN_COS
        var hub = h.t - radius / c
        if hub > reach:
            return WheelHit.miss()
        # The touch point of a wheel of this radius resting at `hub`: equal to
        # the swept-sphere answer on a plane, and the tangent point (not the
        # point under the mount) is where the tire force acts.
        var centre = mount + down * hub
        return WheelHit(True, h.body, hub, centre - h.normal * radius, h.normal)


struct SphereWheel(WheelCast):
    def __init__(out self):
        pass

    def cast(
        self,
        cs: ColliderSet,
        poses: List[Pose3],
        mount: Vec3,
        down: Vec3,
        axle: Vec3,
        reach: Real,
        radius: Real,
        half_width: Real,
        f: QueryFilter,
    ) -> WheelHit:
        var h = sphere_cast(cs, poses, mount, radius, down, reach, f)
        if not h.hit:
            return WheelHit.miss()
        if h.start_solid and dot(h.normal, -down) < _SUPPORT_COS:
            return RayWheel().cast(cs, poses, mount, down, axle, reach, radius, half_width, f)
        return WheelHit(True, h.body, h.t, h.point, h.normal)


struct CapsuleWheel(WheelCast):
    def __init__(out self):
        pass

    def cast(
        self,
        cs: ColliderSet,
        poses: List[Pose3],
        mount: Vec3,
        down: Vec3,
        axle: Vec3,
        reach: Real,
        radius: Real,
        half_width: Real,
        f: QueryFilter,
    ) -> WheelHit:
        var h = capsule_cast(
            cs, poses, mount - axle * half_width, mount + axle * half_width, radius, down, reach, f
        )
        if not h.hit:
            return WheelHit.miss()
        if h.start_solid and dot(h.normal, -down) < _SUPPORT_COS:
            return RayWheel().cast(cs, poses, mount, down, axle, reach, radius, half_width, f)
        return WheelHit(True, h.body, h.t, h.point, h.normal)
