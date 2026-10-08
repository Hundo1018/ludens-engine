"""Destruction and fracture in the production solver (ROADMAP 17.5).

`geometry.polytope` / `geometry.fracture_cut` / `geometry.convex_decomp` make
the pieces; this module makes them REAL: every fragment is a hull body in a
`ContactScene6` (`add_hull`), so it collides with the rest of the scene -- boxes,
other hulls, soft bodies -- takes part in island sleep, and is solved by the same
sweep as anything else. Nothing here is a parallel physics path.

  * BONDS. Two fragments that shared a Voronoi face are joined by one WELD joint
    (`physics.joints6.JOINT_WELD`: ball + full angular lock) anchored at the
    centre of the shared face. The bond's strength is a stress times the seam
    area, and it is installed as the joint's break threshold
    (`ContactScene6.set_joint_break`, 17.29), so a weld breaks when the force
    or torque it carries exceeds what that much seam can hold. Welded bodies
    do not collide with each other (`ContactScene6._collect_pairs`); the step
    after a bond breaks they do. `FractureSet.poll` turns newly broken welds
    into `FractureEvent`s -- exactly once each, whenever it is called.
  * ISLANDS. A bonded structure is one island (joints are island edges), so it
    sleeps as a whole and wakes as a whole; a shattered one becomes many small
    islands that sleep one by one -- no fracture-specific sleep logic exists
    or is needed.
  * BUDGET. `enforce_budget` removes FREE fragments (no live bond) beyond
    `max_free`, sleeping ones and small ones first, counting each removal in
    `diag.counters.FRAGMENT_EVICTED`.
  * RUNTIME CUT. `cut_fragment` / `replace_fragment` swap a fragment for the
    pieces of a plane (or many-plane) cut: the pieces keep the parent's pose and
    velocity field (v + w x r), and every joint of the parent is re-anchored to
    the piece that holds its anchor point.

Fragment shapes are stored BODY-LOCAL (centroid at the origin), the same frame
the hull collider uses, so the stored polytope and the collider can never drift.
"""

from std.math import sqrt
from std.collections import Dict
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.gjk import ConvexPoly, gjk_intersect
from geometry.polytope import Polytope
from geometry.fracture_cut import FragmentSet, cut_by_planes
from collision.broadphase import BroadPhase
from diag.counters import FRAGMENT_EVICTED
from .rigid6 import QuatBody6, Inertia3
from .solver6 import ContactScene6
from .solver_config import SolverConfig
from .joints6 import Joint6, JOINT_BROKEN, JOINT_WELD
from .body_set import BodyId

comptime EVENT_BOND_BROKEN = 0
comptime EVENT_EVICTED = 1


def debris_config() -> SolverConfig:
    """Solver settings for scenes full of fracture debris: the default sleep
    tolerances (1 cm/s, 0.05 rad/s) are tuned for boxes, which settle exactly
    flat; a shard of irregular shape keeps rocking on its contact patch at a
    few cm/s and 0.2 rad/s for seconds without ever being at rest in any way
    a player could see, so debris sleeps at 10x those speeds. Everything else is
    the stock configuration."""
    var cfg = SolverConfig()
    cfg.lin_sleep_tol = 0.1
    cfg.ang_sleep_tol = 0.5
    return cfg^


@fieldwise_init
struct FractureEvent(Copyable, ImplicitlyCopyable, Movable):
    """`kind` is `EVENT_BOND_BROKEN` (a weld released; `frag_b == -1` when the
    other side is an external body such as the ground) or `EVENT_EVICTED`
    (fragment `frag_a` left the scene under the budget)."""

    var kind: Int
    var bond: Int
    var frag_a: Int
    var frag_b: Int


def _v3(x: Float64, y: Float64, z: Float64) -> Vec3:
    return Vec3(Real(x), Real(y), Real(z), 0)


struct FractureSet(Movable):
    """Fragments, bonds and budget of one or more fractured objects."""

    var density: Real
    var max_free: Int
    # fragments
    var shape: List[Polytope]  # body-local, centroid at the origin
    var body: List[Int]  # scene body index
    var bid: List[BodyId]
    var vol: List[Float64]
    var alive: List[Bool]
    var nbond: List[Int]  # live bonds touching the fragment
    var seed: List[Int]
    var part: List[Int]
    # bonds
    var bond_a: List[Int]  # fragment index, -1 = external body
    var bond_b: List[Int]
    var bond_body_a: List[Int]
    var bond_body_b: List[Int]
    var bond_joint: List[Int]
    var bond_area: List[Float64]
    var bond_live: List[Bool]
    var events: List[FractureEvent]

    def __init__(out self, density: Real, max_free: Int):
        self.density = density
        self.max_free = max_free
        self.shape = List[Polytope]()
        self.body = List[Int]()
        self.bid = List[BodyId]()
        self.vol = List[Float64]()
        self.alive = List[Bool]()
        self.nbond = List[Int]()
        self.seed = List[Int]()
        self.part = List[Int]()
        self.bond_a = List[Int]()
        self.bond_b = List[Int]()
        self.bond_body_a = List[Int]()
        self.bond_body_b = List[Int]()
        self.bond_joint = List[Int]()
        self.bond_area = List[Float64]()
        self.bond_live = List[Bool]()
        self.events = List[FractureEvent]()

    # ------------------------------------------------------------- queries
    def fragments(self) -> Int:
        return len(self.shape)

    def alive_count(self) -> Int:
        var n = 0
        for i in range(len(self.alive)):
            if self.alive[i]:
                n += 1
        return n

    def free_count(self) -> Int:
        var n = 0
        for i in range(len(self.alive)):
            if self.alive[i] and self.nbond[i] == 0:
                n += 1
        return n

    def live_bonds(self) -> Int:
        var n = 0
        for b in range(len(self.bond_live)):
            if self.bond_live[b]:
                n += 1
        return n

    # ------------------------------------------------------------ spawning
    def _spawn_one[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        p: Polytope,
        pos: Vec3,
        rot: Quat,
        lin: Vec3,
        ang: Vec3,
        seed: Int,
        part: Int,
    ) -> Int:
        """One fragment from a polytope in the OBJECT frame whose origin sits
        at `pos` with orientation `rot` (moving with `lin`, spinning at `ang`).
        Returns the fragment index, or -1 for a polytope too flat to be a body."""
        var vol = p.volume()
        if p.is_empty() or vol <= 1e-9:  # under a cubic millimetre
            return -1
        var c = p.centroid()
        var verts = p.hull_vertices(c[0], c[1], c[2], 1e-9)
        if len(verts) < 12:
            return -1
        var hv = List[Real](capacity=len(verts))
        for k in range(len(verts)):
            hv.append(Real(verts[k]))
        var off = rot.rotate(_v3(c[0], c[1], c[2]))
        var mass = self.density * Real(vol)
        var ii = p.inertia_diag()
        var inertia = Inertia3(
            mass,
            max(self.density * Real(ii[0]), Real(1e-9)),
            max(self.density * Real(ii[1]), Real(1e-9)),
            max(self.density * Real(ii[2]), Real(1e-9)),
        )
        var v = lin + Vec3(
            ang[1] * off[2] - ang[2] * off[1],
            ang[2] * off[0] - ang[0] * off[2],
            ang[0] * off[1] - ang[1] * off[0],
            0,
        )
        var body = QuatBody6(pos + off, rot, v, ang, inertia)
        var id = sc.add_hull(body^, hv^, False)
        self.shape.append(p.moved(-c[0], -c[1], -c[2]))
        self.body.append(id.index())
        self.bid.append(id)
        self.vol.append(vol)
        self.alive.append(True)
        self.nbond.append(0)
        self.seed.append(seed)
        self.part.append(part)
        return len(self.shape) - 1

    def spawn[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        frags: FragmentSet,
        pos: Vec3,
        rot: Quat,
        lin: Vec3,
        ang: Vec3,
    ) -> Int:
        """Add every fragment of `frags` (object-frame polytopes) as a hull
        body. Returns the index of the first new fragment; fragments of this
        call are `[first, first + count)` where `count` is the number actually
        added (flat slivers are skipped)."""
        var first = len(self.shape)
        for i in range(frags.count()):
            _ = self._spawn_one(sc, frags.cells[i], pos, rot, lin, ang, frags.seed[i], frags.part[i])
        return first

    # --------------------------------------------------------------- bonds
    def _add_bond[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        fa: Int,
        fb: Int,
        ba: Int,
        bb: Int,
        world: Vec3,
        area: Float64,
        strength: Real,
        floor_g: Real,
    ) raises -> Int:
        var qa = sc.bset.bodies[ba].rotation()
        var qb = sc.bset.bodies[bb].rotation()
        var la = sc.bset.bodies[ba].to_local(world)
        var lb = sc.bset.bodies[bb].to_local(world)
        var j = sc.add_joint(Joint6.weld(ba, bb, la, lb, qa.conjugate() * qb))
        # a thin seam still holds a little weight: the threshold never drops
        # below `floor_g` times the lighter side's weight, so sliver faces do
        # not shear off under gravity alone
        var vmin = Float64(1e300)
        if fa >= 0:
            vmin = min(vmin, self.vol[fa])
        if fb >= 0:
            vmin = min(vmin, self.vol[fb])
        var force = max(strength * Real(area), floor_g * Real(9.8) * self.density * Real(vmin))
        var arm = max(sqrt(area), vmin ** (1.0 / 3.0))
        var torque = force * Real(0.5 * arm)
        sc.set_joint_break(j, force, torque)
        self.bond_a.append(fa)
        self.bond_b.append(fb)
        self.bond_body_a.append(ba)
        self.bond_body_b.append(bb)
        self.bond_joint.append(j)
        self.bond_area.append(area)
        self.bond_live.append(True)
        if fa >= 0:
            self.nbond[fa] += 1
        if fb >= 0:
            self.nbond[fb] += 1
        return len(self.bond_live) - 1

    def bond_neighbors[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        first: Int,
        stress: Real,
        floor_g: Real = 30,
    ) raises -> Int:
        """Weld every pair of fragments `[first, ..)` that shared a Voronoi
        face (a cap tag naming the other's seed within the same part). The
        break force is `stress * seam area`, floored at `floor_g` times the
        lighter fragment's weight. Returns the number of bonds."""
        if stress <= 0:
            raise Error("FractureSet.bond_neighbors: stress must be > 0")
        var key = Dict[Int, Int]()
        for i in range(first, len(self.shape)):
            key[self.part[i] * 1000003 + self.seed[i]] = i
        var made = 0
        for i in range(first, len(self.shape)):
            if not self.alive[i]:
                continue
            var seen = Dict[Int, Bool]()
            for f in range(self.shape[i].nt()):
                var tg = self.shape[i].tag[f]
                if tg < 0 or tg in seen:
                    continue
                seen[tg] = True
                var k = key.get(self.part[i] * 1000003 + tg, -1)
                if k <= i:
                    continue  # no such fragment, or the pair is made from k's side
                var pa = self.shape[i].tag_patch(tg)
                if pa[0] <= 0:
                    continue
                var pb = self.shape[k].tag_patch(self.seed[i])
                var area = pa[0] if pb[0] <= 0 else min(pa[0], pb[0])
                var world = sc.bset.bodies[self.body[i]].act(_v3(pa[1], pa[2], pa[3]))
                _ = self._add_bond(
                    sc, i, k, self.body[i], self.body[k], world, area, stress, floor_g
                )
                made += 1
        return made

    def bond_overlapping[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        first: Int,
        stress: Real,
        floor_g: Real = 30,
    ) raises -> Int:
        """Weld fragments of DIFFERENT parts of one concave object whose hulls
        touch or overlap (decomposition parts overlap by up to a voxel, so
        there is no shared face to name). Pairs are found by bounding box then
        GJK; the seam area is estimated as `min(volume)^(2/3)`. O(n^2) over the
        range -- TODO: a broadphase for large concave objects."""
        if stress <= 0:
            raise Error("FractureSet.bond_overlapping: stress must be > 0")
        var made = 0
        var n = len(self.shape)
        var lo = List[Float64](capacity=3 * n)
        var hi = List[Float64](capacity=3 * n)
        for i in range(n):
            var pos = sc.bset.bodies[self.body[i]].position()
            var r = self.shape[i].radius_from(0, 0, 0)
            for a in range(3):
                lo.append(Float64(pos[a]) - r - 1e-6)
                hi.append(Float64(pos[a]) + r + 1e-6)
        for i in range(first, n):
            if not self.alive[i]:
                continue
            for k in range(i + 1, n):
                if not self.alive[k] or self.part[i] == self.part[k]:
                    continue
                if (
                    lo[3 * i] > hi[3 * k] or lo[3 * k] > hi[3 * i]
                    or lo[3 * i + 1] > hi[3 * k + 1] or lo[3 * k + 1] > hi[3 * i + 1]
                    or lo[3 * i + 2] > hi[3 * k + 2] or lo[3 * k + 2] > hi[3 * i + 2]
                ):
                    continue
                var pa = ConvexPoly[3]()
                for v in range(self.shape[i].nv()):
                    pa.add(
                        sc.bset.bodies[self.body[i]].act(
                            _v3(self.shape[i].v[3 * v], self.shape[i].v[3 * v + 1], self.shape[i].v[3 * v + 2])
                        )
                    )
                var pb = ConvexPoly[3]()
                for v in range(self.shape[k].nv()):
                    pb.add(
                        sc.bset.bodies[self.body[k]].act(
                            _v3(self.shape[k].v[3 * v], self.shape[k].v[3 * v + 1], self.shape[k].v[3 * v + 2])
                        )
                    )
                if not gjk_intersect(pa, pb):
                    continue
                var mid = (
                    sc.bset.bodies[self.body[i]].position() + sc.bset.bodies[self.body[k]].position()
                ) * Real(0.5)
                var area = min(self.vol[i], self.vol[k]) ** (2.0 / 3.0)
                _ = self._add_bond(sc, i, k, self.body[i], self.body[k], mid, area, stress, floor_g)
                made += 1
        return made

    def anchor[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        first: Int,
        ext: BodyId,
        pos: Vec3,
        rot: Quat,
        nx: Float64,
        ny: Float64,
        nz: Float64,
        d: Float64,
        tol: Float64,
        stress: Real,
        floor_g: Real = 30,
    ) raises -> Int:
        """Weld every fragment `[first, ..)` whose surface lies in the object-
        frame plane `n . x = d` to the external body `ext` (a wall's footing on
        the ground): the seam is that footprint. Call right after `spawn`."""
        if not sc.bset.is_valid(ext):
            raise Error("FractureSet.anchor: invalid BodyId")
        if stress <= 0:
            raise Error("FractureSet.anchor: stress must be > 0")
        var made = 0
        var qi = rot.conjugate()
        for i in range(first, len(self.shape)):
            if not self.alive[i]:
                continue
            var bp = sc.bset.bodies[self.body[i]].position()
            var co = qi.rotate(bp - pos)  # fragment centroid, object frame
            var dl = d - (nx * Float64(co[0]) + ny * Float64(co[1]) + nz * Float64(co[2]))
            var patch = self.shape[i].plane_patch(nx, ny, nz, dl, tol)
            if patch[0] <= 0:
                continue
            var world = sc.bset.bodies[self.body[i]].act(_v3(patch[1], patch[2], patch[3]))
            _ = self._add_bond(sc, -1, i, ext.index(), self.body[i], world, patch[0], stress, floor_g)
            made += 1
        return made

    # -------------------------------------------------------------- events
    def poll[BP: BroadPhase](
        mut self, sc: ContactScene6[QuatBody6, BP]
    ) -> Int:
        """Collect welds that have broken since the last poll into `events`
        (cleared first). Scans bond state, so it reports each break exactly
        once however often (or rarely) it is called. Returns the new count."""
        self.events.clear()
        for b in range(len(self.bond_live)):
            if not self.bond_live[b]:
                continue
            if sc.joints[self.bond_joint[b]].kind != JOINT_BROKEN:
                continue
            self.bond_live[b] = False
            if self.bond_a[b] >= 0:
                self.nbond[self.bond_a[b]] -= 1
            if self.bond_b[b] >= 0:
                self.nbond[self.bond_b[b]] -= 1
            self.events.append(FractureEvent(EVENT_BOND_BROKEN, b, self.bond_a[b], self.bond_b[b]))
        return len(self.events)

    # -------------------------------------------------------------- budget
    def _release_joints[BP: BroadPhase](
        self, mut sc: ContactScene6[QuatBody6, BP], body: Int, safe: Int
    ):
        """Point every BROKEN joint row that names `body` at body `safe`, so
        the body can be removed (`remove_body` refuses a referenced body)."""
        for c in range(len(sc.joints)):
            if sc.joints[c].kind != JOINT_BROKEN:
                continue
            if sc.joints[c].a == body:
                sc.joints[c].a = safe
            if sc.joints[c].b == body:
                sc.joints[c].b = safe

    def _any_live_body[BP: BroadPhase](
        self, sc: ContactScene6[QuatBody6, BP], not_this: Int
    ) -> Int:
        for k in range(len(sc.bset.bodies)):
            if k != not_this and not sc.bset.is_removed(k):
                return k
        return -1

    def enforce_budget[BP: BroadPhase](
        mut self, mut sc: ContactScene6[QuatBody6, BP]
    ) raises -> Int:
        """Remove free fragments beyond `max_free` (<= 0 disables): sleeping
        ones first, smallest volume first. Returns how many were removed."""
        if self.max_free <= 0:
            return 0
        var removed = 0
        while self.free_count() > self.max_free:
            var pick = -1
            for i in range(len(self.alive)):
                if not self.alive[i] or self.nbond[i] != 0:
                    continue
                if pick < 0:
                    pick = i
                    continue
                var si = sc.bset.sleeping[self.body[i]]
                var sp = sc.bset.sleeping[self.body[pick]]
                if (si and not sp) or (si == sp and self.vol[i] < self.vol[pick]):
                    pick = i
            if pick < 0:
                break
            # a user joint (not a bond) on the fragment blocks the removal
            var blocked = False
            for c in range(len(sc.joints)):
                if sc.joints[c].kind != JOINT_BROKEN and (
                    sc.joints[c].a == self.body[pick] or sc.joints[c].b == self.body[pick]
                ):
                    blocked = True
            if blocked:
                self.nbond[pick] = 1  # not ours to evict: never pick it again
                continue
            var safe = self._any_live_body(sc, self.body[pick])
            if safe < 0:
                break
            self._release_joints(sc, self.body[pick], safe)
            sc.remove_body(self.bid[pick])
            self.alive[pick] = False
            sc.counters.incr(FRAGMENT_EVICTED)
            self.events.append(FractureEvent(EVENT_EVICTED, -1, pick, -1))
            removed += 1
        return removed

    # ---------------------------------------------------------- runtime cut
    def replace_fragment[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        frag: Int,
        pieces: List[Polytope],
    ) raises -> Int:
        """Swap fragment `frag` for `pieces` (polytopes in its BODY-LOCAL
        frame, e.g. from `cut_by_planes`). Each piece becomes a hull body at
        the parent's orientation, moving with the parent's velocity field;
        every joint of the parent is re-anchored to the piece containing (or
        nearest to) its anchor point. Returns the index of the first piece
        fragment, or -1 if no piece was usable (the parent is then kept)."""
        if frag < 0 or frag >= len(self.shape) or not self.alive[frag]:
            raise Error("FractureSet.replace_fragment: dead or unknown fragment")
        var old = self.body[frag]
        var pos = sc.bset.bodies[old].position()
        var q = sc.bset.bodies[old].rotation()
        var w = sc.bset.bodies[old].omega_world()
        var vel_at_pos = sc.bset.bodies[old].velocity_at(pos)
        var first = len(self.shape)
        var pcen = List[Float64]()  # piece centroid (parent-local) per new fragment
        for i in range(len(pieces)):
            var k = self._spawn_one(
                sc, pieces[i], pos, q, vel_at_pos, w, self.seed[frag], self.part[frag]
            )
            if k < 0:
                continue
            var c = pieces[i].centroid()
            pcen.append(c[0])
            pcen.append(c[1])
            pcen.append(c[2])
        var made = len(self.shape) - first
        if made == 0:
            return -1
        # re-anchor every joint of the parent
        for j in range(len(sc.joints)):
            var side_a = sc.joints[j].a == old
            var side_b = sc.joints[j].b == old
            if not (side_a or side_b):
                continue
            var target = first
            if sc.joints[j].kind != JOINT_BROKEN:
                var la = sc.joints[j].la if side_a else sc.joints[j].lb
                var best = Float64(1e300)
                target = -1
                for m in range(made):
                    var dx = Float64(la[0]) - pcen[3 * m]
                    var dy = Float64(la[1]) - pcen[3 * m + 1]
                    var dz = Float64(la[2]) - pcen[3 * m + 2]
                    var dist = dx * dx + dy * dy + dz * dz
                    if dist < best:
                        best = dist
                        target = first + m
                # prefer a piece that actually contains the anchor
                for m in range(made):
                    var pidx = first + m
                    # piece shapes are centred, so test against the shifted point
                    var sx = Float64(la[0]) - pcen[3 * m]
                    var sy = Float64(la[1]) - pcen[3 * m + 1]
                    var sz = Float64(la[2]) - pcen[3 * m + 2]
                    if self.shape[pidx].contains(sx, sy, sz, 1e-7):
                        target = pidx
                        break
                var world = sc.bset.bodies[old].act(la)
                var tb = self.body[target]
                var newl = sc.bset.bodies[tb].to_local(world)
                if side_a:
                    sc.joints[j].a = tb
                    sc.joints[j].la = newl
                else:
                    sc.joints[j].b = tb
                    sc.joints[j].lb = newl
                # keep the bond table in step
                for b in range(len(self.bond_joint)):
                    if self.bond_joint[b] == j and self.bond_live[b]:
                        if side_a:
                            self.bond_a[b] = target
                            self.bond_body_a[b] = tb
                        else:
                            self.bond_b[b] = target
                            self.bond_body_b[b] = tb
                        self.nbond[target] += 1
                        self.nbond[frag] -= 1
            else:
                if side_a:
                    sc.joints[j].a = self.body[target]
                if side_b:
                    sc.joints[j].b = self.body[target]
        sc.remove_body(self.bid[frag])
        self.alive[frag] = False
        return first

    def cut_fragment[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        frag: Int,
        point: Vec3,
        normal: Vec3,
    ) raises -> Int:
        """Cut fragment `frag` by the WORLD plane through `point` with normal
        `normal`. Returns the number of pieces (1 = the plane missed it and
        nothing changed, 2 = split)."""
        if frag < 0 or frag >= len(self.shape) or not self.alive[frag]:
            raise Error("FractureSet.cut_fragment: dead or unknown fragment")
        var planes = List[Float64](capacity=4)
        var nl = length(normal)
        if nl <= 0:
            raise Error("FractureSet.cut_fragment: zero normal")
        var qi = sc.bset.bodies[self.body[frag]].rotation().conjugate()
        var nloc = qi.rotate(normal / nl)
        var ploc = sc.bset.bodies[self.body[frag]].to_local(point)
        planes.append(Float64(nloc[0]))
        planes.append(Float64(nloc[1]))
        planes.append(Float64(nloc[2]))
        planes.append(
            Float64(nloc[0]) * Float64(ploc[0])
            + Float64(nloc[1]) * Float64(ploc[1])
            + Float64(nloc[2]) * Float64(ploc[2])
        )
        return self.cut_fragment_planes(sc, frag, planes)

    def cut_fragment_planes[BP: BroadPhase](
        mut self,
        mut sc: ContactScene6[QuatBody6, BP],
        frag: Int,
        planes_local: List[Float64],
    ) raises -> Int:
        """Cut fragment `frag` by every plane of `planes_local` (flat
        `[nx, ny, nz, d]`, BODY-LOCAL frame) at once; the pieces replace it.
        One call can yield thousands of pieces. Returns the piece count."""
        if frag < 0 or frag >= len(self.shape) or not self.alive[frag]:
            raise Error("FractureSet.cut_fragment_planes: dead or unknown fragment")
        var pieces = cut_by_planes(self.shape[frag], planes_local, 0.0)
        if len(pieces) <= 1:
            return len(pieces)
        var first = self.replace_fragment(sc, frag, pieces)
        if first < 0:
            return 1
        return len(self.shape) - first
