# tier: integration
"""Projectile hits to damage, hits to ability targets (ROADMAP 17.70 /
17.71 wiring, `gameplay.hit_pipeline`).

  1. Falloff: base 40, full to 10 m, 25 % from 50 m on. Hits at 5, 30 and
     80 m flown take 40, 25 and 10 (fixed point); a hit on a body that is
     not an actor (map -1) or outside the map is skipped; each damage
     sends one `DamageEvent` with the target actor.
  2. A kill is reported once: two lethal hits in a row, one `killed`.
  3. `targets_from_hits`: distinct owners in first-hit order.
  4. far <= near raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from gameplay.rules import Rules, Actor
from gameplay.projectile import ProjectileHit
from gameplay.combat import HitResult
from gameplay.hit_pipeline import projectile_damage, targets_from_hits, DamageEvent
from scheduler.events import Channel

comptime HEALTH = 0
comptime Z = Vec3(0, 0, 0, 0)


def ph(body: Int, travelled: Real) -> ProjectileHit:
    return ProjectileHit(0, body, Z, Z, Z, 0, travelled)


def main() raises:
    var s = Suite("projectile_damage")
    var rules = Rules(HEALTH)
    var actors = List[Actor]()
    for _ in range(3):
        actors.append(Actor(1, 1))
    for a in range(3):
        actors[a].attrs.set_base(HEALTH, 1000)
    # scene bodies 0..5; bodies 1, 3, 4 are actors 0, 1, 2
    var body_actor: List[Int] = [-1, 0, -1, 1, 2, -1]
    var ch = Channel[DamageEvent]()
    var rd = ch.register_reader()
    var hits: List[ProjectileHit] = [ph(1, 5), ph(3, 30), ph(4, 80), ph(0, 5), ph(9, 5)]
    var total = projectile_damage(hits, body_actor, rules, actors, 40, 10, 50, 0.25, 0, 7, ch)
    var evs = List[DamageEvent]()
    ch.read(rd, evs)
    print("falloff: health", actors[0].attrs.base[HEALTH], actors[1].attrs.base[HEALTH], actors[2].attrs.base[HEALTH], " total", total, " events", len(evs))
    s.check(actors[0].attrs.base[HEALTH] == 960 and actors[1].attrs.base[HEALTH] == 975 and actors[2].attrs.base[HEALTH] == 990, "5 / 30 / 80 m: 40 / 25 / 10")
    s.check(total == 75 and len(evs) == 3 and evs[1].target == 1 and evs[0].source == 7, "non-actor and unmapped bodies skipped; one event per damage")

    actors[1].attrs.set_base(HEALTH, 30)
    var two: List[ProjectileHit] = [ph(3, 1), ph(3, 1)]
    _ = projectile_damage(two, body_actor, rules, actors, 40, 10, 50, 0.25, 0, 7, ch)
    var evs2 = List[DamageEvent]()
    ch.read(rd, evs2)
    var kills = 0
    for e in evs2:
        if e.killed:
            kills += 1
    s.check(actors[1].dead and kills == 1, "two lethal hits: one kill")

    var mh: List[HitResult] = [HitResult(0, 4, 0, Z, Z, Z, 1), HitResult(1, 2, 0, Z, Z, Z, 1), HitResult(2, 4, 1, Z, Z, Z, 1), HitResult(3, 7, 0, Z, Z, Z, 1)]
    var tg = targets_from_hits(mh)
    s.check(len(tg) == 3 and tg[0] == 4 and tg[1] == 2 and tg[2] == 7, "targets: distinct owners in first-hit order")

    var raised = False
    try:
        _ = projectile_damage(hits, body_actor, rules, actors, 40, 50, 10, 0.25, 0, 7, ch)
    except:
        raised = True
    s.check(raised, "far <= near raises")
    s.finish()
