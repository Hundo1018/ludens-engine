# tier: integration
"""Ragdoll control (ROADMAP 17.66, `gameplay.ragdoll_ctl`).

  1. Segment masses: proportional to box volume, summing to the total; a
     `Ragdoll` built with them has those body masses.
  2. Mode machine, scripted: a 50 N s hit -> STUMBLE (strength 0.3), back
     to ACTIVE after 0.6 s when balanced; a 150 N s hit -> LIMP (0), held
     while moving, GETUP after 0.5 s still and grounded (face up / down from
     the torso), ragdoll blend weight 1 -> 0 over 0.8 s, then ACTIVE; lost
     balance in ACTIVE -> STUMBLE -> LIMP if still unbalanced. The state
     round-trips through `BinWriter` / `BinReader` and continues the same.
  3. Balance assist, zero gravity, 2-bone ragdoll (root + torso, both
     simulated): the COM starts 5 cm off the support centre and the PD
     root force brings it within 1 mm in 3 s; after a push whose capture
     point leaves the polygon the result asks for a step to the capture
     point; moving the support there whenever asked (a character stepping)
     stops the body within 4 steps with the COM over the last support.
  4. Grab: a box welded to a kinematic hand follows it; a heavier pull
     breaks the weld (its kind becomes `JOINT_BROKEN`); `release` lets the
     box fall.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from procedural.anim_graph import Pose, to_world
from physics.rigid6 import QuatBody6, Inertia3, Pose6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.serialize import BinWriter, BinReader
from physics.joints6 import JOINT_BROKEN
from gameplay.ragdoll import Ragdoll
from gameplay.ragdoll_ctl import (
    segment_masses, RagdollModes, balance_assist, grab, release,
    MODE_ACTIVE, MODE_STUMBLE, MODE_LIMP, MODE_GETUP,
)
from gameplay.balance import center_of_mass

comptime DT: Real = 1.0 / 60.0


def two_bone_pose() -> Pose:
    var local = Pose(2)
    local.set(0, Vec3(0, 1.0, 0, 0), Quat(0, 0, 0, 1))
    local.set(1, Vec3(0, 0.3, 0, 0), Quat(0, 0, 0, 1))
    return to_world(local, [-1, 0])


def main() raises:
    var s = Suite("ragdoll_ctl")
    var cfg = SolverConfig()

    # 1. masses
    var halves: List[Vec3] = [Vec3(0.15, 0.15, 0.1, 0), Vec3(0.15, 0.3, 0.1, 0)]
    var ms = segment_masses(30.0, halves)
    s.check(abs(ms[0] + ms[1] - 30) < 1e-4 and abs(ms[1] / ms[0] - 2) < 1e-5, "masses: sum 30, torso box twice the volume -> twice the mass")
    var sc0 = ContactScene6[QuatBody6]()
    var offs: List[Vec3] = [Vec3(0, 0.15, 0, 0), Vec3(0, 0.3, 0, 0)]
    var rd0 = Ragdoll(sc0, two_bone_pose(), [-1, 0], halves, offs.copy(), [True, True], masses=ms.copy())
    var m0 = 1 / sc0.bset.bodies[rd0.ids[0].index()].inv_mass()
    var m1 = 1 / sc0.bset.bodies[rd0.ids[1].index()].inv_mass()
    print("ragdoll body masses", m0, m1)
    s.check(abs(m0 - ms[0]) < 1e-3 and abs(m1 - ms[1]) < 1e-3, "Ragdoll uses the per-bone masses")

    # 2. modes
    var md = RagdollModes()
    md.on_hit(50)
    var st = md.update(0.1, 0, True, True, 1)
    var stumble_ok = md.mode == MODE_STUMBLE and st == md.stumble_strength
    for _ in range(6):
        st = md.update(0.1, 0, True, True, 1)
    var back_ok = md.mode == MODE_ACTIVE and st == 1
    md.on_hit(150)
    st = md.update(0.1, 2.0, False, False, 1)
    var limp_ok = md.mode == MODE_LIMP and st == 0 and md.blend == 1
    for _ in range(10):
        _ = md.update(0.1, 2.0, True, False, 1)  # still sliding: stays limp
    var held = md.mode == MODE_LIMP
    for _ in range(6):
        st = md.update(0.1, 0.05, True, False, -0.8)
    var getup_ok = md.mode == MODE_GETUP and not md.face_up and st == 1
    # snapshot mid get-up, continue both
    _ = md.update(0.2, 0, True, True, 1)
    var w = BinWriter()
    md.write_state(w)
    var copy = RagdollModes()
    var r = BinReader(w.b.copy())
    copy.read_state(r)
    var blends = List[Real]()
    var same = True
    for _ in range(8):
        _ = md.update(0.1, 0, True, True, 1)
        _ = copy.update(0.1, 0, True, True, 1)
        blends.append(md.blend)
        same = same and md.mode == copy.mode and md.blend == copy.blend and md.timer == copy.timer
    print("get-up blend:", blends[0], blends[2], blends[4], " mode at end", md.mode)
    var end_ok = md.mode == MODE_ACTIVE and md.blend == 0
    var lost = RagdollModes()
    _ = lost.update(0.1, 0, True, False, 1)
    var lost1 = lost.mode == MODE_STUMBLE
    for _ in range(7):
        _ = lost.update(0.1, 0, True, False, 1)
    s.check(stumble_ok and back_ok, "hit 50: STUMBLE at 0.3, ACTIVE again after 0.6 s balanced")
    s.check(limp_ok and held and getup_ok, "hit 150: LIMP, held while sliding, GETUP face down after 0.5 s still")
    s.check(end_ok and blends[0] > blends[4], "get-up blend falls to 0, then ACTIVE")
    s.check(lost1 and lost.mode == MODE_LIMP, "balance lost: STUMBLE, then LIMP")
    s.check(same, "mode state round-trips through BinWriter / BinReader and continues the same")

    # 3. balance assist in zero gravity
    var sc = ContactScene6[QuatBody6]()
    var rd = Ragdoll(sc, two_bone_pose(), [-1, 0], halves, offs.copy(), [True, True], masses=ms.copy())
    rd.set_strength(sc, 1)
    var support: List[Vec3] = [Vec3(-0.05, 0, -0.15, 0), Vec3(0.25, 0, -0.15, 0), Vec3(0.25, 0, 0.15, 0), Vec3(-0.05, 0, 0.15, 0)]
    var g0 = Vec3(0, 0, 0, 0)
    var start = center_of_mass(sc, rd.ids)[0]
    for _ in range(180):
        _ = balance_assist(sc, rd, support, 0.0, 9.8, 400.0, 120.0, 600.0)
        sc.step(DT, g0, cfg)
    var com = center_of_mass(sc, rd.ids)[0]
    print("assist: COM x", start[0], "->", com[0], " (support centre 0.1)")
    s.check(abs(com[0] - 0.1) < 1e-3 and abs(com[2]) < 1e-3, "PD root force brings the COM over the support centre (1 mm)")
    rd.hit(sc, 0, Vec3(60, 0, 0, 0), sc.bset.bodies[rd.ids[0].index()].position())
    var res = balance_assist(sc, rd, support, 0.0, 9.8, 400.0, 120.0, 600.0)
    print("after a 60 N s push: capture point x", res.capture[0], " margin", res.margin, " need step", res.need_step)
    s.check(res.need_step and res.step_to[0] > 0.25, "push: capture point outside -> step to it")
    # stepping: whenever the capture point leaves the support, put the
    # support (a foot) under it -- as a character takes another step
    var sx = res.step_to[0]
    var sz = res.step_to[2]
    var steps = 1
    var r2 = res
    for _ in range(300):
        var moved: List[Vec3] = [Vec3(sx - 0.15, 0, sz - 0.15, 0), Vec3(sx + 0.15, 0, sz - 0.15, 0), Vec3(sx + 0.15, 0, sz + 0.15, 0), Vec3(sx - 0.15, 0, sz + 0.15, 0)]
        r2 = balance_assist(sc, rd, moved, 0.0, 9.8, 400.0, 120.0, 600.0)
        if r2.need_step:
            sx = r2.step_to[0]
            sz = r2.step_to[2]
            steps += 1
        sc.step(DT, g0, cfg)
    var com2 = center_of_mass(sc, rd.ids)[0]
    var v2 = center_of_mass(sc, rd.ids)[1]
    print("after", steps, "steps: margin", r2.margin, " COM x", com2[0], " (support centre", sx, ")  speed", length(v2))
    s.check(steps <= 4 and not r2.need_step and abs(com2[0] - sx) < 5e-3 and length(v2) < 1e-2, "stepping to the capture point stops the push within 4 steps; COM over the last support")

    # 4. grab / break / release
    var gs = ContactScene6[QuatBody6]()
    var hand = gs.add(QuatBody6.at_rest(Vec3(0, 2, 0, 0), Inertia3.box(1, 0.05, 0.05, 0.05)), Vec3(0.05, 0.05, 0.05, 0), False)
    gs.set_kinematic(hand)
    var box = gs.add(QuatBody6.at_rest(Vec3(0, 1.8, 0, 0), Inertia3.box(2, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var j = grab(gs, hand, box, 500.0, 500.0)
    for k in range(60):
        gs.move_to(hand, Pose6(Vec3(Real(k + 1) * 0.01, 2, 0, 0), Quat(0, 0, 0, 1)), DT)
        gs.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    var bp = gs.bset.bodies[box.index()].position()
    print("carried box at", bp[0], bp[1], " (hand at 0.6, 2.0)")
    s.check(abs(bp[0] - 0.6) < 0.02 and abs(bp[1] - 1.8) < 0.02, "the welded box follows the hand")
    var heavy = gs.add(QuatBody6.at_rest(Vec3(0.6, 1.6, 0, 0), Inertia3.box(500, 0.1, 0.1, 0.1)), Vec3(0.1, 0.1, 0.1, 0), False)
    var j2 = grab(gs, box, heavy, 500.0, 500.0)
    for _ in range(10):
        gs.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    # `broken_joints` lists only the last step's breaks; the kind stays
    var broke = gs.joints[j2].kind == JOINT_BROKEN
    s.check(broke, "a 500 kg load breaks a 500 N weld")
    release(gs, j)
    var y0 = gs.bset.bodies[box.index()].position()[1]
    for _ in range(30):
        gs.step(DT, Vec3(0, -9.8, 0, 0), cfg)
    var y1 = gs.bset.bodies[box.index()].position()[1]
    print("released box fell", y0 - y1, "m in 0.5 s")
    s.check(y0 - y1 > 0.5, "release: the box falls")
    s.finish()
