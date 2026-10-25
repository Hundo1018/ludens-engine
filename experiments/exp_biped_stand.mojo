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
    capture point), clamped to 0.4 rad, in x and z;
  * ankle torque PD: a torque pair on each shin / foot, tau = K theta +
    D theta_dot (theta the COM's lean over the ankles, x and z), half per
    leg, on top of the drives; optionally a push (N s, x and z / 2) on
    the torso at 1 s.

Measured (2026-10-18): every row falls, between 1.7 and 3.4 s; stiffer drives
fall sooner, more substeps only delay it; with the ankle lean the body
falls forward instead of backward. Drive targets are not ankle torques:
the drive is a soft spring toward a target whose stiffness and timing the
controller does not set, and the stance is an inverted pendulum on it.
The ankle torque PD stands the full 10 s unpushed at K 800-1600 with
D = 0.1 K (K 400 falls at 3.5 s; D = 0.2 K at K 1600 fell at 0.8 s); a
sweep of K 400-1200 and D 0.1-0.4 K found no setting that survives a
10 N s push (falls 2.2-2.4 s), and D = 0.4 K diverges at once: an
explicit torque at 60 Hz. Fallen torque-PD runs end with COM x printed as
0.0, not examined further. Push recovery needs the
torque inside the solver (an implicit ankle actuator) or hip / stepping
strategies -- still open.
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


def run(hz: Real, torque: Real, kp: Real, substeps: Int, ank: Real = 0, ank_d: Real = 0, push: Real = 0) raises -> Tuple[Real, Real]:
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
        if k == 60 and push != 0:
            rd.hit(sc, 1, Vec3(push, 0, push * 0.5, 0), sc.bset.bodies[rd.ids[1].index()].position())
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
        if ank != 0:
            # ankle torque PD on the COM's lean over the ankles: tau = ank theta + ank_d theta_dot
            var c = center_of_mass(sc, rd.ids)
            var lf = sc.bset.bodies[rd.ids[4].index()].position()
            var rf = sc.bset.bodies[rd.ids[7].index()].position()
            var ax = (lf[0] + rf[0]) * 0.5 - 0.05
            var az = (lf[2] + rf[2]) * 0.5
            var h = c[0][1] - 0.06
            var th = (c[0][0] - ax) / h
            var thd = c[1][0] / h
            var ps = (c[0][2] - az) / h
            var psd = c[1][2] / h
            var t = Vec3(-(ank * ps + ank_d * psd), 0, ank * th + ank_d * thd, 0) * 0.5
            for leg in [3, 6]:
                sc.add_torque(rd.ids[leg], t)
                sc.add_torque(rd.ids[leg + 1], t * -1)
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
    var gains: List[Real] = [400, 800, 1200, 1600]
    for g in gains:
        for p in [0, 10]:
            var r = run(8, 400, 0, 1, g, 0.1 * g, Real(p))
            print("| ankle torque PD", g, "/", 0.1 * g, ", push", p, "N s at 1 s | 8 | 400 | 1 |", r[0], "|", r[1], "|")
    var hz_stiff: List[Real] = [15, 40]
    var kp2: List[Real] = [0.3, 1.0, 2.0]
    for h in hz_stiff:
        for kp in kp2:
            for p in [0, 10, 20]:
                var r = run(h, 3000, kp, 1, 0, 0, Real(p))
                print("| stiff ankle servo kp", kp, ", push", p, "N s | ", h, "| 3000 | 1 |", r[0], "|", r[1], "|")
