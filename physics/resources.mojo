"""Resource accounting and limits for a `ContactScene6` (ROADMAP 17.79).

`resource_report(scene)` returns the bytes held per subsystem: every
per-body list of the body set, the collider set with its hull / mesh /
heightfield / SDF payloads, the warm-start contact cache, joints and the
soft bodies. It counts elements in use (`len` x `size_of`), not reserved
capacity, and not the broadphase's own structure (backend-specific), so it
is a floor on what the scene holds. `bytes_per_body` divides the body-set
and collider-header bytes by the slot count -- the answer to "how much more
for 5000 more boxes" before loading them.

`Limits` caps bodies and joints; `check_room(scene, limits, bodies, joints)`
raises if adding that many would exceed a cap (the public-API row of
`docs/ARCHITECTURE.md` §2: check at the boundary, before the hot path).
The contact cap is `SolverConfig.max_contacts`: on the hot path, so the
newest manifolds over it are dropped and counted (`CONTACT_DROPPED`).
"""

from std.sys import size_of
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from geometry.aabb import AABB
from collision.broadphase import BroadPhase
from collision.collider_set import ColliderSet, ShapeDesc
from .rigid6 import Body6
from .body_set import BodySet
from .solver6 import ContactScene6
from .contact6 import ContactConstraint


@fieldwise_init
struct ResourceReport(Copyable, Movable, Writable):
    var bodies: Int
    var colliders: Int
    var shapes: Int  # hull / mesh / heightfield / SDF payloads
    var contacts: Int
    var joints: Int
    var soft: Int

    def total(self) -> Int:
        return self.bodies + self.colliders + self.shapes + self.contacts + self.joints + self.soft

    def write_to[W: Writer](self, mut w: W):
        w.write(
            "bodies ", self.bodies, " B, colliders ", self.colliders, " B, shapes ", self.shapes,
            " B, contacts ", self.contacts, " B, joints ", self.joints, " B, soft ", self.soft,
            " B, total ", self.total(), " B",
        )


@fieldwise_init
struct Limits(Copyable, ImplicitlyCopyable, Movable):
    """Caps for `check_room`; 0 = no cap."""

    var max_bodies: Int
    var max_joints: Int


def _lb[T: Copyable](l: List[T]) -> Int:
    return len(l) * size_of[T]()


def body_set_bytes[B: Body6](b: BodySet[B]) -> Int:
    var t = _lb(b.bodies) + _lb(b.motion) + _lb(b.sleeping) + _lb(b.sleep_timer) + _lb(b.island)
    t += _lb(b.restitution) + _lb(b.can_sleep) + _lb(b.friction) + _lb(b.friction_combine)
    t += _lb(b.restitution_combine) + _lb(b.generation) + _lb(b.grav_on) + _lb(b.grav)
    t += _lb(b.frozen_motion) + _lb(b.lin_damping) + _lb(b.ang_damping) + _lb(b.gravity_scale)
    t += _lb(b.locks) + _lb(b.max_lin) + _lb(b.max_ang) + _lb(b.force) + _lb(b.torque)
    t += _lb(b.sleep_lin) + _lb(b.sleep_ang) + _lb(b.report) + _lb(b.static_friction)
    t += _lb(b.rolling) + _lb(b.spinning) + _lb(b.contact_hertz) + _lb(b.contact_zeta)
    t += _lb(b.adhesion) + _lb(b.free)
    return t


def collider_header_bytes(c: ColliderSet) -> Int:
    var t = _lb(c.shape) + _lb(c.half) + _lb(c.hull_id) + _lb(c.mesh_id) + _lb(c.kid_desc)
    t += _lb(c.kid_pos) + _lb(c.kid_rot) + _lb(c.comp_first) + _lb(c.comp_n) + _lb(c.world_aabb)
    t += _lb(c.category) + _lb(c.mask) + _lb(c.sensor)
    return t


def shape_payload_bytes(c: ColliderSet) -> Int:
    var t = 0
    for k in range(len(c.hulls)):
        t += _lb(c.hulls[k].v) + _lb(c.hulls[k].f) + _lb(c.hulls[k].fo)
    for k in range(len(c.meshes)):
        ref m = c.meshes[k]
        t += _lb(m.v) + _lb(m.idx) + _lb(m.nrm) + _lb(m.active) + _lb(m.bvh.nodes)
    for k in range(len(c.fields)):
        t += _lb(c.fields[k].h) + _lb(c.fields[k].bmin) + _lb(c.fields[k].bmax)
    for k in range(len(c.sdfs)):
        t += _lb(c.sdfs[k].values)
    return t


def resource_report[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP]) -> ResourceReport:
    var soft = 0
    for k in range(len(sc.softs)):
        soft += _lb(sc.softs[k].pts) + _lb(sc.softs[k].edges)
    return ResourceReport(
        body_set_bytes(sc.bset),
        collider_header_bytes(sc.colliders),
        shape_payload_bytes(sc.colliders),
        _lb(sc.cache) + _lb(sc.sensor_pairs),
        _lb(sc.joints) + _lb(sc.jext) + _lb(sc.drives),
        soft,
    )


def bytes_per_body[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP]) -> Int:
    """Body-set plus collider-header bytes per slot (shape payloads and
    contacts excluded: they depend on what the body is and touches)."""
    var n = len(sc.bset.bodies)
    if n == 0:
        return 0
    return (body_set_bytes(sc.bset) + collider_header_bytes(sc.colliders)) // n


def check_room[B: Body6, BP: BroadPhase](sc: ContactScene6[B, BP], limits: Limits, bodies: Int, joints: Int = 0) raises:
    """Raise if adding `bodies` bodies and `joints` joints would pass a cap."""
    if bodies < 0 or joints < 0:
        raise Error("check_room: counts must be >= 0")
    var live = len(sc.bset.bodies) - len(sc.bset.free)
    if limits.max_bodies > 0 and live + bodies > limits.max_bodies:
        raise Error("check_room: " + String(live + bodies) + " bodies would exceed max_bodies " + String(limits.max_bodies))
    if limits.max_joints > 0 and len(sc.joints) + joints > limits.max_joints:
        raise Error("check_room: " + String(len(sc.joints) + joints) + " joints would exceed max_joints " + String(limits.max_joints))
