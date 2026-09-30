"""Active ragdoll: an animation pose as the drive target of a physical body
(ROADMAP 17.2).

One box per bone in a `ContactScene6`, a ball joint where each bone meets
its parent, and a soft angular drive (`physics.joints6.AngularDrive`) per
joint pulling the child's orientation relative to its parent toward what
the animation says. Per bone, the caller picks at construction whether the
bone is SIMULATED (dynamic, driven) or ANIMATED (kinematic, carried exactly
along the animation by `move_to`) -- a partial ragdoll such as "legs
animated, arms physical" is just a mask. At run time:

  `follow(anim_world, dt)`  animated bones move to their animated pose,
                            simulated bones get new drive targets
  `set_strength(s)`         scales every drive's torque cap: 1 = tracks the
                            animation, 0 = limp (a hit, a fall)
  `hit(bone, impulse, at)`  an impulse on one bone (it reacts, the drives
                            pull it back unless strength is low)
  `physics_pose()`          the bodies as bone world transforms
  `blend_world(anim, phys, w)` per-bone blend for the fall -> get-up
                            transition: w goes from 1 (ragdoll) to 0
                            (animation) and at 0 the result IS the animation

Poses here are WORLD transforms (`procedural.anim_graph.to_world` turns a
local pose into one). A body sits at its bone's origin plus `offset` (the
middle of the segment, in the bone's frame).
"""

from geometry.vec import Real, Vec3
from geometry.quat import Quat
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.joints6 import Joint6, AngularDrive
from physics.body_set import BodyId
from procedural.anim_graph import Pose, blend


struct Ragdoll(Movable):
    var parent: List[Int]
    var ids: List[BodyId]
    var drive: List[Int]  # drive index per bone (-1: root or animated)
    var simulated: List[Bool]
    var offset: List[Vec3]
    var max_torque: Real

    def __init__(
        out self,
        mut sc: ContactScene6[QuatBody6],
        pose_world: Pose,
        var parent: List[Int],
        half: List[Vec3],
        var offset: List[Vec3],
        simulated: List[Bool],
        mass: Real = 5,
        hertz: Real = 8,
        zeta: Real = 1,
        max_torque: Real = 400,
    ) raises:
        self.parent = parent^
        self.offset = offset^
        self.simulated = simulated.copy()
        self.ids = List[BodyId]()
        self.drive = List[Int]()
        self.max_torque = max_torque
        var n = pose_world.bones
        for b in range(n):
            var q = pose_world.q(b)
            var c = pose_world.p(b) + q.rotate(self.offset[b])
            var body = QuatBody6.at_rest(c, Inertia3.box(mass, half[b][0], half[b][1], half[b][2]))
            body.q = q
            var id = sc.add(body^, half[b], False)
            sc.set_can_sleep(id, False)
            if not simulated[b]:
                sc.set_kinematic(id)
            self.ids.append(id)
        for b in range(n):
            var p = self.parent[b]
            if p < 0:
                self.drive.append(-1)
                continue
            var ia = self.ids[p].index()
            var ib = self.ids[b].index()
            var pivot = pose_world.p(b)
            _ = sc.add_joint(
                Joint6.ball(
                    ia, ib,
                    sc.bset.bodies[ia].to_local(pivot),
                    sc.bset.bodies[ib].to_local(pivot),
                )
            )
            if simulated[b]:
                var target = pose_world.q(p).conjugate() * pose_world.q(b)
                self.drive.append(
                    sc.add_drive(AngularDrive.make(ia, ib, target, hertz, zeta, max_torque))
                )
            else:
                self.drive.append(-1)

    def follow(mut self, mut sc: ContactScene6[QuatBody6], anim_world: Pose, dt: Real) raises:
        for b in range(len(self.ids)):
            var q = anim_world.q(b)
            if not self.simulated[b]:
                var c = anim_world.p(b) + q.rotate(self.offset[b])
                sc.move_to(self.ids[b], Pose6(c, q), dt)
            elif self.drive[b] >= 0:
                var p = self.parent[b]
                sc.drives[self.drive[b]].target = anim_world.q(p).conjugate() * q

    def set_strength(mut self, mut sc: ContactScene6[QuatBody6], s: Real):
        for b in range(len(self.drive)):
            if self.drive[b] >= 0:
                sc.drives[self.drive[b]].max_torque = self.max_torque * s

    def hit(mut self, mut sc: ContactScene6[QuatBody6], bone: Int, impulse: Vec3, at: Vec3) raises:
        var i = self.ids[bone].index()
        sc.wake(self.ids[bone])
        sc.bset.bodies[i].apply_impulse(impulse, at)

    def physics_pose(self, sc: ContactScene6[QuatBody6]) -> Pose:
        var out = Pose(len(self.ids))
        for b in range(len(self.ids)):
            ref body = sc.bset.bodies[self.ids[b].index()]
            var q = body.rotation()
            out.set(b, body.position() - q.rotate(self.offset[b]), q)
        return out^


def blend_world(anim_world: Pose, phys_world: Pose, w: Real) -> Pose:
    """Per-bone blend of two world poses, `w` = weight of the ragdoll. At
    w = 0 the result is the animation exactly (the end of a get-up)."""
    return blend(anim_world, phys_world, w)
