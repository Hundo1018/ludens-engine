"""Whether a drive-held biped ragdoll stands under gravity (ROADMAP 17.66).

A negative result, kept so it can be re-run.

An 8-bone, 70 kg biped (pelvis, torso, thighs, shins, feet; `Ragdoll` with
`segment_masses`, neighbouring bones not colliding) stands on a static
floor box, feet flat, every bone simulated, no root force. Each row runs
10 s at 60 Hz and reports when the torso centre first drops below 1.0 m
(it starts at 1.33 m) and where the COM ends.

  * passive: every drive targets the standing pose, at 8 / 15 / 25 / 40 Hz
    (torque cap 400 / 2000 N m), 1 / 4 / 8 solver substeps;
  * ankle lean: both ankle drives target a lean phi = kp (feet centre -
    capture point), clamped to 0.4 rad, in x and z.

Measured (2026-10-18): every row falls, between 1.7 and 3.4 s; stiffer drives
fall sooner, more substeps only delay it; with the ankle lean the body
falls forward instead of backward. Drive targets are not ankle torques:
the drive is a soft spring toward a target whose stiffness and timing the
controller does not set, and the stance is an inverted pendulum on it.
Standing needs torque-level control (ankle / hip torques from the COM and
capture point, e.g. a PD on the centroidal state), which is still open.
"""

from std.math import sin, cos
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from procedural.anim_graph import Pose
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from gameplay.ragdoll import Ragdoll
from gameplay.ragdoll_ctl import segment_masses
from gameplay.balance import center_of_mass, capture_point


def run(hz: Real, torque: Real, kp: Real, substeps: Int) raises -> Tuple[Real, Real]:
    """(time the torso centre first drops below 1 m, -1 if never; final COM x)."""
    var pw = Pose(8)
    var I = Quat(0, 0, 0, 1)
    pw.set(0, Vec3(0, 1.0, 0, 0), I)
    pw.set(1, Vec3(0, 1.08, 0, 0), I)
    for side in range(2):
        var z = Real(-0.1) if side == 0 else Real(0.1)
        pw.set(2 + 3 * side, Vec3(0, 0.95, z, 0), I)
        pw.set(3 + 3 * side, Vec3(0, 0.5, z, 0), I)
        pw.set(4 + 3 * side, Vec3(0, 0.06, z, 0), I)
    var parent: List[Int] = [-1, 0, 0, 2, 3, 0, 5, 6]
    var leg = Vec3(0.06, 0.22, 0.06, 0)
    var shin = Vec3(0.05, 0.22, 0.05, 0)
    var foot = Vec3(0.12, 0.03, 0.05, 0)
    var half: List[Vec3] = [Vec3(0.15, 0.08, 0.15, 0), Vec3(0.15, 0.25, 0.1, 0), leg, shin, foot, leg, shin, foot]
    var down = Vec3(0, -0.22, 0, 0)
    var heel = Vec3(0.05, -0.03, 0, 0)
    var off: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(0, 0.25, 0, 0), down, down, heel, down, down, heel]
    var sim = List[Bool](length=8, fill=True)
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 5, 0.5, 5)), Vec3(5, 0.5, 5, 0), True)
    var rd = Ragdoll(sc, pw, parent^, half, off^, sim, hertz=hz, max_torque=torque, collide_connected=False, masses=segment_masses(70.0, half))
    var cfg = SolverConfig()
    cfg.substeps = substeps
    var dt = Real(1.0 / 60.0)
    var fell = Real(-1)
    for k in range(600):
        if kp != 0:
            var c = center_of_mass(sc, rd.ids)
            var cp = capture_point(c[0], c[1], 0.0, 9.8)
            var lf = sc.bset.bodies[rd.ids[4].index()].position()
            var rf = sc.bset.bodies[rd.ids[7].index()].position()
            var phi = max(min(kp * ((lf[0] + rf[0]) * 0.5 - cp[0]), Real(0.4)), Real(-0.4))
            var psi = max(min(kp * ((lf[2] + rf[2]) * 0.5 - cp[2]), Real(0.4)), Real(-0.4))
            var q = Quat(0, 0, sin(phi * 0.5), cos(phi * 0.5)) * Quat(sin(-psi * 0.5), 0, 0, cos(-psi * 0.5))
            sc.drives[rd.drive[4]].target = q
            sc.drives[rd.drive[7]].target = q
        sc.step(dt, Vec3(0, -9.8, 0, 0), cfg)
        if fell < 0 and sc.bset.bodies[rd.ids[1].index()].position()[1] < 1.0:
            fell = Real(k + 1) * dt
    return (fell, center_of_mass(sc, rd.ids)[0][0])


def main() raises:
    print("| control | drive Hz | torque cap N m | substeps | falls at s | final COM x m |")
    print("|---|--:|--:|--:|--:|--:|")
    var hzs: List[Real] = [8, 15, 25, 40]
    for h in hzs:
        var cap = Real(400) if h == 8 else Real(2000)
        var r = run(h, cap, 0, 1)
        print("| passive |", h, "|", cap, "| 1 |", r[0], "|", r[1], "|")
    for ss in [4, 8]:
        var r = run(8, 400, 0, ss)
        print("| passive | 8 | 400 |", ss, "|", r[0], "|", r[1], "|")
    var kps: List[Real] = [0.5, 2, 5]
    for kp in kps:
        var r = run(8, 400, kp, 1)
        print("| ankle lean kp", kp, "| 8 | 400 | 1 |", r[0], "|", r[1], "|")
