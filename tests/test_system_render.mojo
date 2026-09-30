# tier: system
"""ROADMAP 17.7 through the runtime: simulation at 60 Hz, frames at 144 Hz.

Every rendered pose of a falling ball lies between the previous and current
tick (never ahead of the simulation, never behind it), rendering is smooth
(no frame repeats the last tick while time has passed -- the stutter that
drawing the latest tick produces), and a teleport shows the destination with
no frame in between."""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.interpolation import LerpNlerp, MotorGeodesic

comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]


def main() raises:
    var s = Suite("system_render")
    var rt = Rt(1.0 / 60.0, Vec3(0, -9.8, 0, 0))
    var ball = rt.spawn_sphere(QuatBody6.at_rest(Vec3(0, 100, 0, 0), Inertia3.box(1, 0.2, 0.2, 0.2)), 0.2, False)
    var bounded = True
    var smooth_frames = 0
    var prev_render = Real(1e9)
    var monotone = True
    for _ in range(144):
        _ = rt.advance(1.0 / 144.0)
        var r = rt.render_pose[MotorGeodesic](ball)
        var i = rt.world.get[RigidBodyRef](ball).id.index()
        if i >= len(rt.history.curr):
            continue  # before the first tick there is nothing to interpolate
        var hi = max(rt.history.prev[i].p[1], rt.history.curr[i].p[1])
        var lo = min(rt.history.prev[i].p[1], rt.history.curr[i].p[1])
        if r.p[1] > hi + 1e-5 or r.p[1] < lo - 1e-5:
            bounded = False
        if r.p[1] != rt.history.curr[i].p[1]:
            smooth_frames += 1
        if r.p[1] > prev_render + 1e-6:
            monotone = False
        prev_render = r.p[1]
    s.check(bounded, "every rendered pose lies between the previous and current tick")
    s.check(monotone, "a falling ball's rendered height never goes back up")
    s.check(smooth_frames > 60, "most frames draw an in-between pose (" + String(smooth_frames) + " of 144)")
    var lerp_pose = rt.render_pose[LerpNlerp](ball)
    var geo_pose = rt.render_pose[MotorGeodesic](ball)
    s.check(abs(lerp_pose.p[1] - geo_pose.p[1]) < 1e-4, "for a non-spinning fall both interpolators agree")

    rt.teleport(ball, Vec3(500, 100, 0, 0))
    var smeared = False
    for _ in range(6):
        _ = rt.advance(1.0 / 144.0)
        var x = rt.render_pose[MotorGeodesic](ball).p[0]
        if x > 1 and x < 499:
            smeared = True
    s.check(not smeared, "no frame draws the ball between its old place and the teleport target")
    s.finish()
