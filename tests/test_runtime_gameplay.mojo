# tier: system
"""`Runtime` steps rules and vehicles (ROADMAP 17.70, 17.74).

Before, a host that wanted effects or a raycast vehicle ticked in step with the
runtime had to call `Rules.step` and `Vehicle.update` itself between
`Runtime.advance` calls, so the order against the scene step was the caller's.

Predictions, written before the first run:

  1. Rules: 1 actor, health 100, a 10-per-30-tick damage effect for 300 ticks,
     driven through `Runtime` one tick per frame, has the same health after 400
     ticks as a bare `Rules` driven for 400 ticks (0, dead), and `take_died`
     returns [0] once, on the same tick the bare `Rules` reports the death.
  2. A flow state without `TICK_SIM` freezes the rules: `rules.tick` does not
     move over 10 frames, and moves again after the pop.
  3. Vehicles: a car and a road added through `Runtime` give the same chassis
     position and velocity, bit for bit, after 240 ticks at full throttle as a
     bare `ContactScene6` driven with `vehicle.update` then `scene.step` (the
     same call order, `Runtime` uses `scene.step`). The car is faster than
     10 m/s and has moved more than 20 m in x.
  4. The input is held and replaceable: after the throttle run,
     `set_vehicle_input` to full brake brings the car under 2 m/s in 300
     ticks. (No no-call control run was made, so this does not show that the
     throttle input alone would have held the speed.)
  5. Extreme: a vehicle index out of range raises; `add_vehicle` on a static
     body raises; `set_rules` after an actor was added raises; despawning the
     chassis keeps the runtime stepping and counts `VEHICLE_FORCE_DROPPED`
     every tick.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from ecs.sparse_backend import SparseSetBackend
from ecs.transform import Transform
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from diag.counters import VEHICLE_FORCE_DROPPED
from gameplay.runtime import Runtime, RigidBodyRef
from gameplay.flow import TICK_TIMERS
from gameplay.rules import (
    FX, OP_ADD, KIND_PERIODIC, STACK_REFRESH, Actor, Rules, EffectDef,
)
from gameplay.vehicle import (
    Vehicle, VehicleConfig, VehicleInput, chassis_body, spawn_chassis,
)
from gameplay.vehicle_wheel import RayWheel

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime Bk = SparseSetBackend[Transform, RigidBodyRef]
comptime Rt = Runtime[Bk, QuatBody6]
comptime HEALTH = 0


def _static(p: Vec3) -> QuatBody6:
    return QuatBody6.at_rest(p, Inertia3.box(1, 1, 1, 1))


def _rules() -> Rules:
    var r = Rules(HEALTH)
    _ = r.define(EffectDef(KIND_PERIODIC, 300, 30, HEALTH, OP_ADD, -10 * FX, 0, 0, STACK_REFRESH, 1))
    return r^


def _actor() -> Actor:
    var a = Actor(1, 1)
    a.attrs.set_base(HEALTH, 100 * FX)
    a.attrs.set_range(HEALTH, 0, 100 * FX)
    return a^


def main() raises:
    var s = Suite("runtime_gameplay")

    # ---- 1. rules through the runtime == bare rules ----
    var ref_rules = _rules()
    var ref_actors = List[Actor]()
    ref_actors.append(_actor())
    _ = ref_rules.apply(ref_actors[0], 0, 0)
    var ref_death = -1
    for t in range(400):
        ref_rules.step(ref_actors)
        if len(ref_rules.deaths) > 0 and ref_death < 0:
            ref_death = t + 1

    var rt = Rt(DT, G)
    rt.set_rules(_rules())
    var idx = rt.add_actor(_actor())
    _ = rt.rules.apply(rt.actors[idx], 0, 0)
    var died = List[Int]()
    var rt_death = -1
    for t in range(400):
        _ = rt.advance(Float64(DT))
        var d = rt.take_died()
        for k in d:
            died.append(k)
            if rt_death < 0:
                rt_death = t + 1
    var h_ref = ref_actors[0].attrs.value(HEALTH)
    var h_rt = rt.actors[0].attrs.value(HEALTH)
    print("  rules: bare health", h_ref, "dead", ref_actors[0].dead, "at tick", ref_death, "; runtime health", h_rt, "dead", rt.actors[0].dead, "at tick", rt_death)
    s.check(h_ref == h_rt and ref_actors[0].dead == rt.actors[0].dead, "rules: runtime health and dead flag equal the bare Rules")
    s.check(ref_death > 0 and rt_death == ref_death, "rules: death reported on the same tick")
    s.check(len(died) == 1 and died[0] == 0, "rules: take_died returns the actor once")

    # ---- 2. no TICK_SIM: rules do not tick ----
    var p = Rt(DT, G)
    p.set_rules(_rules())
    _ = p.add_actor(_actor())
    _ = p.advance(Float64(DT))
    var t0 = p.rules.tick
    p.flow.push(2, TICK_TIMERS)
    for _ in range(10):
        _ = p.advance(Float64(DT))
    var t_paused = p.rules.tick
    _ = p.flow.pop()
    for _ in range(3):
        _ = p.advance(Float64(DT))
    print("  rules tick: before", t0, "paused", t_paused, "after pop", p.rules.tick)
    s.check(t0 == 1 and t_paused == 1, "pause: rules.tick stays at 1 over 10 frames")
    s.check(p.rules.tick == 4, "pause: three frames after the pop it is 4")

    # ---- 3. vehicle through the runtime == bare scene ----
    var cfg = VehicleConfig()
    var ref_sc = ContactScene6[QuatBody6]()
    ref_sc.events_on = True
    var ref_road = ref_sc.add(_static(Vec3(0, -1, 0, 0)), Vec3(3000, 1, 3000, 0), True)
    ref_sc.set_friction(ref_road.index(), 0.5)
    var ref_id = spawn_chassis(ref_sc, cfg, Vec3(0, 0.72, 0, 0))
    var ref_car = Vehicle[RayWheel].attach(ref_sc, ref_id, cfg.copy(), RayWheel())
    var scfg = SolverConfig()
    for _ in range(240):
        ref_car.update(ref_sc, VehicleInput(1, 0, 0, 0), DT)
        ref_sc.step(DT, G, scfg)

    var vr = Rt(DT, G)
    var road = vr.spawn_body(_static(Vec3(0, -1, 0, 0)), Vec3(3000, 1, 3000, 0), True)
    vr.scene.set_friction(vr.body_of(road).index(), 0.5)
    var chassis = vr.spawn_body(chassis_body(cfg, Vec3(0, 0.72, 0, 0), Quat.identity()), cfg.half, False)
    var k = vr.add_vehicle(chassis, cfg.copy())
    vr.set_vehicle_input(k, VehicleInput(1, 0, 0, 0))
    for _ in range(240):
        _ = vr.advance(Float64(DT))
    var pr = vr.scene.bset.bodies[vr.body_of(chassis).index()].pos
    var pf = ref_sc.bset.bodies[ref_id.index()].pos
    var vv = vr.velocity(chassis)
    var vf = ref_sc.velocity(ref_id)
    var sp = vr.vehicles.items[k].forward_speed(vr.scene)
    print("  vehicle: runtime pos x", pr[0], "bare", pf[0], "; speed", sp)
    s.check(pr[0] == pf[0] and pr[1] == pf[1] and pr[2] == pf[2], "vehicle: position bit-equal to the bare scene")
    s.check(vv[0] == vf[0] and vv[1] == vf[1] and vv[2] == vf[2], "vehicle: velocity bit-equal to the bare scene")
    s.check(sp > 10.0 and pr[0] > 20.0, "vehicle: accelerates (speed " + String(sp) + ", x " + String(pr[0]) + ")")

    # ---- 4. held input, replaced input ----
    var coast = vr.vehicles.items[k].forward_speed(vr.scene)
    vr.set_vehicle_input(k, VehicleInput(0, 1, 0, 0))
    for _ in range(300):
        _ = vr.advance(Float64(DT))
    var braked = vr.vehicles.items[k].forward_speed(vr.scene)
    print("  speed before brake", coast, "after 300 ticks of full brake", braked)
    s.check(braked < 2.0, "input: replacing it with full brake stops the car (" + String(braked) + " m/s)")

    # ---- 5. extremes ----
    var raised = False
    try:
        vr.set_vehicle_input(5, VehicleInput.idle())
    except:
        raised = True
    s.check(raised, "extreme: vehicle index out of range raises")
    raised = False
    try:
        _ = vr.add_vehicle(road, cfg.copy())
    except:
        raised = True
    s.check(raised, "extreme: add_vehicle on a static body raises")
    raised = False
    try:
        var vr2_check = Rt(DT, G)
        _ = vr2_check.add_actor(_actor())
        vr2_check.set_rules(_rules())
    except:
        raised = True
    s.check(raised, "extreme: set_rules after an actor exists raises")

    var before = Int(vr.scene.counters.get(VEHICLE_FORCE_DROPPED))
    vr.despawn(chassis)
    for _ in range(5):
        _ = vr.advance(Float64(DT))
    var dropped = Int(vr.scene.counters.get(VEHICLE_FORCE_DROPPED)) - before
    print("  chassis despawned: VEHICLE_FORCE_DROPPED +", dropped, "over 5 ticks")
    s.check(dropped == 5, "extreme: despawned chassis counts one drop per tick, the runtime keeps stepping")

    s.finish()
