"""Islands, sleep and wake (audit F11, cluster 10): union-find over the
constraint graph, the island-wide wake rule, the per-body still timers that
put a whole island to sleep together. Free functions over a `BodySet` view
and a flat `(a, b)` edge list -- this module never sees a contact or a joint,
so it imports neither `contact6` nor `joints6`.
"""

from geometry.vec import Real, dot
from .rigid6 import Body6
from .body_set import BodySet
from .solver_config import SolverConfig


def island_count[B: Body6](bset: BodySet[B]) -> Int:
    """Number of distinct dynamic islands from the last `step_soft`."""
    var seen = List[Int]()
    for i in range(len(bset.island)):
        if bset.island[i] < 0:
            continue
        var known = False
        for j in range(len(seen)):
            if seen[j] == bset.island[i]:
                known = True
                break
        if not known:
            seen.append(bset.island[i])
    return len(seen)


def find_root(mut parent: List[Int], i: Int) -> Int:
    var r = i
    while parent[r] != r:
        var pr = parent[r]
        var gp = parent[pr]  # path halving
        parent[r] = gp
        r = gp
    return r


def refresh_islands[B: Body6](
    mut bset: BodySet[B], edges: List[Int], n_contacts: Int
):
    """Union-find over the constraint graph, then the wake rule: an island
    with ANY awake member wakes entirely. `edges` is the flat list
    `a0, b0, a1, b1, ...` of every constraint this step, the `n_contacts`
    contacts first and then the joints (the order the solver has always
    merged them in).

    Only DYNAMIC bodies merge islands -- statics and kinematics do not (17.24:
    a kinematic platform drives dynamics but never joins their sleep/wake
    bookkeeping). A kinematic body still gets a real label: its own index,
    since the union-find never touches it, so `find_root` on it is a
    self-loop. That singleton "island" holds only itself and no constraints
    (a constraint touching it is filed under its dynamic partner's label),
    and it is what lets the island-parallel path advance a kinematic body's
    pose at all -- without a label of its own it would sit frozen there even
    though the serial path moves it fine."""
    var n = len(bset.bodies)
    var parent = List[Int]()
    for i in range(n):
        parent.append(i)
    for c in range(len(edges) // 2):
        var a = edges[2 * c]
        var b = edges[2 * c + 1]
        if bset.is_dynamic(a) and bset.is_dynamic(b):
            parent[find_root(parent, a)] = find_root(parent, b)
    # labels + island-wide wake
    while len(bset.island) < n:
        bset.island.append(-1)
    for i in range(n):
        bset.island[i] = find_root(parent, i) if bset.moves(i) else -1
    # 17.24: a MOVING kinematic body must wake a sleeping dynamic body it
    # touches -- an elevator that starts moving under a sleeping box must not
    # leave it frozen. This cannot go through the island-membership wake
    # below: a kinematic body is deliberately excluded from every dynamic
    # island, so it never has an "awake island member" to propagate from.
    # Gated on the kinematic body's OWN velocity being nonzero -- a STATIONARY
    # kinematic must NOT do this, or the zero-velocity-kinematic == static
    # parity test breaks (test_kinematic.mojo). Contacts only, not joints.
    for c in range(n_contacts):
        wake_if_kinematic_moving(bset, edges[2 * c], edges[2 * c + 1])
        wake_if_kinematic_moving(bset, edges[2 * c + 1], edges[2 * c])
    for i in range(n):
        if not bset.is_dynamic(i) or bset.sleeping[i]:
            continue
        # island member i is awake -> wake everyone sharing its label
        for j in range(n):
            if bset.island[j] == bset.island[i] and bset.sleeping[j]:
                bset.sleeping[j] = False
                bset.sleep_timer[j] = 0


def wake_if_kinematic_moving[B: Body6](mut bset: BodySet[B], ka: Int, kb: Int):
    """If `ka` is a MOVING kinematic body and `kb` is a sleeping dynamic
    one, wake `kb`'s island (`_wake_island`) -- see the call site's
    docstring in `_refresh_islands`. A no-op for every other combination
    (including a motionless kinematic, or `kb` not asleep to begin
    with)."""
    if not bset.is_kinematic(ka) or not bset.is_dynamic(kb) or not bset.sleeping[kb]:
        return
    var v = bset.bodies[ka].linear_velocity()
    var w = bset.bodies[ka].omega_world()
    if dot(v, v) == 0 and dot(w, w) == 0:
        return
    wake_island(bset, kb)


def wake_island[B: Body6](mut bset: BodySet[B], i: Int):
    """Wake body `i`'s current island: every body sharing its
    `bset.island` label -- the same island-wide rule `_refresh_islands`
    already applies automatically once any member is awake, exposed as
    its own method so the public `wake`/`teleport` API (17.25) can reach
    it without duplicating that inline version. A no-op for a static or
    kinematic `i` (`is_dynamic` gate) -- neither has meaningful sleep
    state to wake."""
    if not bset.is_dynamic(i):
        return
    bset.sleeping[i] = False
    bset.sleep_timer[i] = 0
    var lbl = bset.island[i]
    for j in range(len(bset.bodies)):
        if bset.island[j] == lbl and bset.sleeping[j]:
            bset.sleeping[j] = False
            bset.sleep_timer[j] = 0


def update_sleep[B: Body6](mut bset: BodySet[B], dt: Real, cfg: SolverConfig):
    """Advance per-body still-timers; a whole island sleeps together.
    Kinematic bodies never enter this (ROADMAP 17.24: they never sleep,
    full stop -- not "asleep when still", just outside the concept, the
    same way statics always were); `can_sleep=False` (17.25) keeps a
    dynamic body's timer at 0 forever, which starves its whole island's
    `all_still` check below without needing a second gate there."""
    var n = len(bset.bodies)
    for i in range(n):
        if not bset.is_dynamic(i) or bset.sleeping[i] or not bset.can_sleep[i]:
            continue
        var v = bset.bodies[i].linear_velocity()
        var w = bset.bodies[i].omega_world()
        if (
            dot(v, v) < cfg.lin_sleep_tol * cfg.lin_sleep_tol
            and dot(w, w) < cfg.ang_sleep_tol * cfg.ang_sleep_tol
        ):
            bset.sleep_timer[i] += dt
        else:
            bset.sleep_timer[i] = 0
    # sleep islands whose every member has been still long enough
    for i in range(n):
        if not bset.is_dynamic(i) or bset.sleeping[i]:
            continue
        var all_still = True
        for j in range(n):
            if bset.island[j] == bset.island[i] and bset.sleep_timer[
                j
            ] < cfg.sleep_time:
                all_still = False
                break
        if all_still:
            for j in range(n):
                if bset.island[j] == bset.island[i]:
                    bset.sleeping[j] = True
                    bset.bodies[j].halt()


def island_labels[B: Body6](bset: BodySet[B]) -> List[Int]:
    """Distinct island labels in first-seen body order (the partition order
    the island-parallel solve uses)."""
    var labels = List[Int]()
    for i in range(len(bset.bodies)):
        if bset.island[i] < 0:
            continue
        var known = False
        for k in range(len(labels)):
            if labels[k] == bset.island[i]:
                known = True
                break
        if not known:
            labels.append(bset.island[i])
    return labels^
