# tier: system
"""Combat wiring (ROADMAP 17.71, `gameplay.hit_pipeline`): animation events
open the hitbox, hits go through the 17.70 damage pipeline into a channel,
reactions reach the 17.67 mover and bonded fracture walls.

  1. Ordinary: an attack clip fires "open" at 0.2 s and "close" at 0.5 s of
     a 1 s loop; a blade swept one turn per second about the attacker
     (2 pi rad/s, in step with the loop) passes a target standing at the
     window's middle angle (2.2 rad) once per loop. Over 2 s (two loops) the window opens twice and
     the target is hit exactly twice (once per window, dedup inside a
     window); with the window closed the same sweep hits nothing.
  2. Integration: each hit deals 30 x the hurtbox's part multiplier (head
     2.0) through `Rules.damage` (10 % resistance): health 100 -> 46 -> 0,
     two `DamageEvent`s, `killed` exactly once. Knockback adds 3 m/s along
     the blade's motion to the target's mover, which slides while still
     walking; `explode_movers` pushes a character in the open and not one
     behind a wall; a 6000 N s blast 0.6 m in front of a bonded 12-cell
     fracture wall breaks bonds (none break in the control run; 300 N s
     moves ~300 kg cells by 0.4 m/s and breaks none). A shockwave front at
     40 m/s reaches a crate 2.2 m away at tick 4 and one 19.5 m away at
     tick 30 (d / speed / dt, rounded up), pushing each once.
  3. Extreme: hits on owners outside the actor list are skipped; a zero
     radius explosion pushes nobody.
"""

from std.math import cos, sin
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.polytope import Polytope
from geometry.fracture_cut import scatter_seeds, voronoi_fracture, FragmentSet
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from ecs.entity import Entity
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.fracture import FractureSet
from procedural.anim import AnimClip
from procedural.anim_events import EventTrack
from procedural.anim_state import AnimGraph
from scheduler.events import Channel
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.animator import AnimatorRef, AnimEvent, AnimLibrary, Animators, tick_animators
from gameplay.combat import Swing, Hurtbox, HitResult, DETECT_ARC
from gameplay.rules import Rules, Actor
from gameplay.character import CharacterController
from gameplay.movement import Mover
from physics.fields import WaterVolume
from gameplay.explosion import explode, Shockwave
from gameplay.hit_pipeline import HitWindow, DamageEvent, deal_damage, knockback, explode_movers

comptime DT: Real = 1.0 / 60.0
comptime AR = AnimatorRef[3]
comptime Rt = Runtime[SparseSetBackend[Transform, RigidBodyRef, AR], QuatBody6]
comptime HEALTH = 0
comptime ZERO = Vec3(0, 0, 0, 0)


def _lib() raises -> AnimLibrary:
    var c = AnimClip(1, 11, 10, True)
    for f in range(11):
        c.set_key(f, 0, Vec3(0, 1, 0, 0), Quat(0, 0, 0, 1))
    var tr = EventTrack()
    tr.add(0.2, 1)
    tr.add(0.5, 2)
    var lib = AnimLibrary()
    _ = lib.add(c^, tr^)
    return lib^


def _attack(open_ids: Bool) raises -> Tuple[Int, Int, List[HitResult]]:
    """(windows opened, hits, the hits) over 2 s."""
    var rt = Rt(DT, Vec3(0, -9.8, 0, 0))
    var e = rt.world.spawn()
    var anims = Animators()
    var g = AnimGraph(1)
    _ = g.add_state(0, 1)
    rt.world.set(e, AR(anims.add(g^, -1)))
    var lib = _lib()
    var ch = Channel[AnimEvent]()
    var reader = ch.register_reader()
    var win = HitWindow(e, 1 if open_ids else 99, 2)
    var sw = Swing(0, 0.5, 1.5, 0.05, DETECT_ARC, 0.02)
    var boxes = List[Hurtbox]()
    # target standing in the arc at 2.2 rad, 1 m from the pivot; head capsule
    var at = Vec3(cos(Real(2.2)), 0, -sin(Real(2.2)), 0)
    boxes.append(Hurtbox(0, 5, 1, 2.0, at + Vec3(0, -0.5, 0, 0), at + Vec3(0, 0.5, 0, 0), 0.15))
    var all = List[HitResult]()
    var buf = List[AnimEvent]()
    for k in range(120):
        tick_animators[AID=3](rt, anims, lib, DT, ch)
        buf.clear()
        ch.read(reader, buf)
        ch.update()
        var rot = Quat.from_axis_angle(Vec3(0, 1, 0, 0), Real(k + 1) * DT * 6.2831853)
        win.feed(buf, sw, ZERO, rot)
        for h in win.step(sw, ZERO, rot, boxes):
            all.append(h)
    return (win.opened, len(all), all^)


def _wall_bonds(blast: Bool) raises -> Int:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -1, 0, 0), Inertia3.box(1, 30, 1, 30)), Vec3(30, 1, 30, 0), True)
    var wall = Polytope.box(0, 1.0, 0, 1.5, 1.0, 0.15)
    var seeds = scatter_seeds(wall.bounds(), 12, 5, 0.0, 1.0, -0.15, 0.5)
    var fs = FragmentSet(List[Polytope](), List[Int](), List[Int]())
    voronoi_fracture(wall, seeds, 0, 1e-5, fs)
    var set = FractureSet(2000, 0)
    var first = set.spawn(sc, fs, ZERO, Quat.identity(), ZERO, ZERO)
    _ = set.bond_neighbors(sc, first, 5e4)
    var broken = 0
    for k in range(60):
        if blast and k == 10:
            var rep = explode(sc, Vec3(1.0, 1, 0.6, 0), 2, 6000)
            var jm = Real(0)
            for j in rep.impulse:
                jm = max(jm, length(j))
            print("  blast reached", len(rep.bodies), "fragments, largest impulse", jm)
        sc.step_soft(DT, Vec3(0, -9.8, 0, 0))
        broken += set.poll(sc)
    return broken


def main() raises:
    var s = Suite("hit_pipeline")

    # ---- window from animation events --------------------------------------------------------------------
    var on = _attack(True)
    var off = _attack(False)
    print("  2 s of attack loops: windows opened", on[0], " hits", on[1], ";  window never opened: hits", off[1])
    s.check(on[0] == 2 and on[1] == 2 and off[1] == 0, "one hit per animation window; none with the window closed")

    # ---- damage pipeline ---------------------------------------------------------------------------------
    var rules = Rules(HEALTH)
    var actors = List[Actor]()
    actors.append(Actor(1, 1))
    actors[0].attrs.set_base(HEALTH, 100)
    actors[0].resist[0] = 100  # 10 %
    var dch = Channel[DamageEvent]()
    var dr = dch.register_reader()
    var hp = List[Int]()
    var total = 0
    for k in range(len(on[2])):
        var one = List[HitResult]()
        one.append(on[2][k])
        total += deal_damage(one, rules, actors, 30, 0, 7, dch)
        hp.append(actors[0].attrs.base[HEALTH])
    var evs = List[DamageEvent]()
    dch.read(dr, evs)
    var kills = 0
    for e in evs:
        if e.killed:
            kills += 1
    print("  health after hits", hp[0], hp[1], " events", len(evs), "amounts", evs[0].amount, evs[1].amount, " killed", kills, " bone", evs[0].bone, "source", evs[0].source)
    s.check(hp[0] == 46 and hp[1] == 0 and len(evs) == 2 and kills == 1 and evs[0].amount == 54 and evs[0].bone == 5 and evs[0].source == 7, "30 x 2.0 head x 0.9 resistance: 100 -> 46 -> 0, killed once")
    var stray = List[HitResult]()
    stray.append(HitResult(0, 9, 0, ZERO, ZERO, ZERO, 1))
    s.check(deal_damage(stray, rules, actors, 30, 0, 7, dch) == 0, "a hit on an owner outside the actor list is skipped")

    # ---- knockback through the mover ------------------------------------------------------------------------
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    var movers = List[Mover]()
    movers.append(Mover(CharacterController(Vec3(0, 0.92, 0, 0))))
    var waters = List[WaterVolume]()
    var g = Vec3(0, -9.8, 0, 0)
    for _ in range(30):
        movers[0].update(sc, Vec3(0, 0, 2, 0), False, False, DT, g, waters)
    var push = List[HitResult]()
    push.append(HitResult(0, 0, 0, ZERO, ZERO, Vec3(1, 0, 0, 0), 1))
    knockback(push, movers, 3)
    var x0 = movers[0].cc.position[0]
    for _ in range(60):
        movers[0].update(sc, Vec3(0, 0, 2, 0), False, False, DT, g, waters)
    var dx = movers[0].cc.position[0] - x0
    var vz = movers[0].cc.velocity[2]
    print("  knockback 3 m/s along x while walking 2 m/s along z: slid", dx, "m in 1 s, walking vz", vz)
    s.check(dx > 0.5 and abs(vz - 2) < 1e-3, "knockback slides the character without overwriting its walk")

    # ---- explosion on characters -------------------------------------------------------------------------
    var se = ContactScene6[QuatBody6]()
    _ = se.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    _ = se.add(QuatBody6.at_rest(Vec3(-1.5, 1.5, 0, 0), Inertia3.box(1, 0.1, 1.5, 2)), Vec3(0.1, 1.5, 2, 0), True)
    var two = List[Mover]()
    two.append(Mover(CharacterController(Vec3(3, 0.92, 0, 0))))
    two.append(Mover(CharacterController(Vec3(-3, 0.92, 0, 0))))
    var n = explode_movers(se, Vec3(0, 0.92, 0, 0), 6, 10, two)
    var none = explode_movers(se, Vec3(0, 0.92, 0, 0), 0, 10, two)
    print("  blast at the origin: pushed", n, "; open mover ext", two[0].ext, " behind the wall", two[1].ext, ";  zero radius pushed", none)
    s.check(n == 1 and two[0].ext[0] > 4.9 and length(two[1].ext) == 0 and none == 0, "pushes the character in the open (falloff 1 - 3/6), not the one behind the wall")

    # ---- shockwave ----------------------------------------------------------------------------------------
    var sw_sc = ContactScene6[QuatBody6]()
    var near = sw_sc.add(QuatBody6.at_rest(Vec3(2.2, 0, 0, 0), Inertia3.box(10, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False).index()
    var far = sw_sc.add(QuatBody6.at_rest(Vec3(0, 0, 19.5, 0), Inertia3.box(10, 0.3, 0.3, 0.3)), Vec3(0.3, 0.3, 0.3, 0), False).index()
    var wave = Shockwave(ZERO, 25, 50, 40)
    var t_near = -1
    var t_far = -1
    var pushes = 0
    for k in range(1, 61):
        var rep = wave.step(sw_sc, DT)
        for b in rep.bodies:
            pushes += 1
            if b == near and t_near < 0:
                t_near = k
            if b == far and t_far < 0:
                t_far = k
        sw_sc.step_soft(DT, ZERO)
    print("  shockwave at 40 m/s: crate at 2.2 m pushed at tick", t_near, ", at 19.5 m at tick", t_far, ";  pushes", pushes, " far crate vz", sw_sc.bset.bodies[far].vel[2])
    s.check(t_near == 4 and t_far == 30 and pushes == 2 and sw_sc.bset.bodies[far].vel[2] > 0, "the front reaches each crate at d / speed, once")

    # ---- explosion on a bonded fracture wall ------------------------------------------------------------
    var calm = _wall_bonds(False)
    var blown = _wall_bonds(True)
    print("  bonded wall, 1 s: bonds broken without blast", calm, ", with the blast", blown)
    s.check(calm == 0 and blown > 0, "the blast breaks the wall's bonds")
    s.finish()
