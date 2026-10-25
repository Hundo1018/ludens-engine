"""Combat wiring (ROADMAP 17.71): animation events to hitboxes to damage
and reactions.

  * `HitWindow`: opens a `Swing` (clearing its per-swing dedup set) when the
    entity's animator fires `open_id` and closes it on `close_id`
    (`gameplay.animator.AnimEvent`, as `tick_animators` sends them); outside
    the window the blade is only tracked, never tested.
  * `deal_damage`: each hit's base damage times the hurtbox's part
    multiplier goes through `rules.Rules.damage` (resistance, shield,
    health); every hit is sent as a `DamageEvent` (health lost, killed once)
    into a `scheduler.events.Channel`.
  * `projectile_damage` (17.70): projectile hits (`projectile.ProjectileHit`,
    which name a scene body) mapped to actors through `body_actor`
    (-1 = not an actor), with linear damage falloff over the distance
    flown (full up to `near`, `far_frac` of it from `far` on), through the
    same `Rules.damage` and `DamageEvent` channel as melee hits.
  * `targets_from_hits`: the distinct owners of a tick's hits, in first-hit
    order -- the target list `abilities.Abilities.activate` takes.
  * `knockback`: adds the hit direction times a speed to the target's
    `Mover` external-velocity accumulator (17.67), so it is not overwritten
    by walking.
  * `explode_movers`: an explosion's push on characters: the same linear
    falloff as `explosion.explode`, blocked when a ray from the centre to
    the character hits anything first, applied to the `Mover` accumulator.
    (Ragdolls take `Ragdoll.hit`; bonded fracture walls break from the
    bodies' impulses on the next `FractureSet.poll`.)
"""

from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from ecs.entity import Entity
from collision.world_query import QueryFilter
from collision.broadphase import BroadPhase
from physics.rigid6 import Body6
from physics.solver6 import ContactScene6
from scheduler.events import Channel
from .animator import AnimEvent
from .combat import Swing, Hurtbox, HitResult
from .projectile import ProjectileHit
from .rules import Rules, Actor
from .movement import Mover


@fieldwise_init
struct DamageEvent(Copyable, ImplicitlyCopyable, Movable):
    var target: Int  # hurtbox owner == actor index
    var bone: Int
    var amount: Int  # health lost (fixed point, `rules.FX`)
    var killed: Bool  # this hit took the target to 0
    var point: Vec3
    var source: Int


struct HitWindow(Copyable, Movable):
    var entity: Entity
    var open_id: Int
    var close_id: Int
    var active: Bool
    var opened: Int  # windows opened so far

    def __init__(out self, entity: Entity, open_id: Int, close_id: Int):
        self.entity = entity
        self.open_id = open_id
        self.close_id = close_id
        self.active = False
        self.opened = 0

    def feed(mut self, events: List[AnimEvent], mut swing: Swing, pivot: Vec3, rot: Quat):
        """Apply this tick's animation events (other entities' are ignored)."""
        for e in events:
            if e.entity != self.entity:
                continue
            if e.id == self.open_id:
                swing.begin(pivot, rot)
                self.active = True
                self.opened += 1
            elif e.id == self.close_id:
                self.active = False

    def step(mut self, mut swing: Swing, pivot: Vec3, rot: Quat, boxes: List[Hurtbox]) -> List[HitResult]:
        """Hits of this tick's blade motion while open; none while closed."""
        if not self.active:
            swing.pivot = pivot
            swing.rot = rot
            return List[HitResult]()
        return swing.step(pivot, rot, boxes)


def deal_damage(
    hits: List[HitResult], mut rules: Rules, mut actors: List[Actor], base: Int, dtype: Int, source: Int,
    mut events: Channel[DamageEvent],
) -> Int:
    """Damage every hit's owner; returns the total health lost. Hits on an
    owner outside `actors` are skipped."""
    var total = 0
    for h in hits:
        if h.owner < 0 or h.owner >= len(actors):
            continue
        var was = actors[h.owner].dead
        var lost = rules.damage(actors[h.owner], h.owner, Int(Real(base) * h.mult), dtype)
        events.send(DamageEvent(h.owner, h.bone, lost, actors[h.owner].dead and not was, h.point, source))
        total += lost
    return total


def projectile_damage(
    hits: List[ProjectileHit], body_actor: List[Int], mut rules: Rules, mut actors: List[Actor],
    base: Int, near: Real, far: Real, far_frac: Real, dtype: Int, source: Int,
    mut events: Channel[DamageEvent],
) raises -> Int:
    """Falloff: full damage up to `near` metres flown, `far_frac` of it
    from `far` on, linear between. Returns the total health lost."""
    if not (far > near) or not (far_frac >= 0 and far_frac <= 1):
        raise Error("projectile_damage: far > near and 0 <= far_frac <= 1")
    var total = 0
    for h in hits:
        if h.body < 0 or h.body >= len(body_actor):
            continue
        var a = body_actor[h.body]
        if a < 0 or a >= len(actors):
            continue
        var f = Real(1)
        if h.travelled >= far:
            f = far_frac
        elif h.travelled > near:
            f = 1 - (1 - far_frac) * (h.travelled - near) / (far - near)
        var was = actors[a].dead
        var lost = rules.damage(actors[a], a, Int(Real(base) * f), dtype)
        events.send(DamageEvent(a, -1, lost, actors[a].dead and not was, h.point, source))
        total += lost
    return total


def targets_from_hits(hits: List[HitResult]) -> List[Int]:
    var out = List[Int]()
    for h in hits:
        var seen = False
        for o in out:
            if o == h.owner:
                seen = True
        if not seen and h.owner >= 0:
            out.append(h.owner)
    return out^


def knockback(hits: List[HitResult], mut movers: List[Mover], speed: Real):
    """Push each hit owner's mover along the weapon's motion."""
    for h in hits:
        if h.owner >= 0 and h.owner < len(movers):
            movers[h.owner].add_velocity(h.dir * speed)


def explode_movers[B: Body6, BP: BroadPhase](
    sc: ContactScene6[B, BP], center: Vec3, radius: Real, speed: Real, mut movers: List[Mover],
    filter: QueryFilter = QueryFilter.all(),
) -> Int:
    """Add a radial push (`speed` at the centre, 0 at `radius`) to every
    mover in range with a clear line from the centre; returns how many."""
    var n = 0
    if not (radius > 0) or not (speed > 0):
        return 0
    for k in range(len(movers)):
        var d = movers[k].cc.position - center
        var l = length(d)
        if not (l < radius):
            continue
        var dir = Vec3(0, 1, 0, 0)
        if l > 1e-9:
            dir = d / l
            if sc.ray_cast(center, dir, l, filter).hit:
                continue
        movers[k].add_velocity(dir * (speed * (1 - l / radius)))
        n += 1
    return n
