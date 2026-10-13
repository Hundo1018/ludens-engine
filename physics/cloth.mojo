"""Cloth on an arbitrary triangle mesh (ROADMAP 17.56).

`gpu_cloth` / `vbd_cloth` are fixed W x H grid prototypes (top row pinned,
four structural springs, a floor). `MeshCloth` takes any triangle mesh:

  * stretch: one XPBD distance constraint per mesh edge (rest = its length);
  * bending: per interior edge, a distance constraint between the two
    vertices opposite it (rest = their distance in the input pose) with its
    own compliance -- a cross-edge bending model, not a dihedral one;
  * mass: each triangle's area x `density` (kg / m^2), a third to each
    corner;
  * pins (`pin`) and attachments to rigid bodies (`attach`: the vertex
    follows a body-local point every substep);
  * collision with the scene's colliders (`step`): each vertex is a sphere of
    radius `thickness` pushed out along the collider's closest-point normal
    (`collision.world_query`, every shape kind), with Coulomb-style friction
    on the tangential motion of that substep; one-way (the cloth does not
    push the bodies);
  * wind: per triangle, a drag force `drag * area * (w . n) n` on the relative
    wind w = wind - triangle velocity, spread over its corners;
  * tearing: an edge whose constraint force (|lambda| / h^2) exceeds
    `break_force` is cut, with the bending constraint across it.

Constraints run in a fixed order (Gauss-Seidel), so a run is deterministic.
`MeshCloth` also implements `physics.continuum.ContinuumSolver` (`advance`
without a scene: pins, attachments frozen, wind, no collision).
"""

from std.math import sqrt, isfinite
from std.collections import Dict
from geometry.vec import Real, Vec3, dot, cross
from collision.world_query import QueryFilter, overlap_sphere, point_distance
from collision.broadphase import BroadPhase
from .rigid6 import Body6
from .solver6 import ContactScene6
from .state_io import StateWriter, StateReader
from .continuum import ContinuumSolver, ContinuumHealth


def _len(v: Vec3) -> Real:
    return sqrt(dot(v, v))


struct MeshCloth(ContinuumSolver):
    var x: List[Vec3]
    var prev: List[Vec3]
    var v: List[Vec3]
    var w: List[Real]  # inverse mass; 0 = pinned or attached
    var tris: List[Int]
    var ea: List[Int]
    var eb: List[Int]
    var rest: List[Real]
    var lam: List[Real]
    var torn: List[Bool]
    var ba: List[Int]
    var bb: List[Int]
    var brest: List[Real]
    var blam: List[Real]
    var bedge: List[Int]  # the stretch edge each bending constraint crosses
    var stretch_compliance: Real
    var bend_compliance: Real
    var break_force: Real
    var damping: Real  # velocity kept per substep
    var thickness: Real
    var friction: Real
    var wind: Vec3
    var drag: Real
    var substeps: Int
    var iters: Int
    var att_vert: List[Int]
    var att_body: List[Int]
    var att_local: List[Vec3]

    def __init__(
        out self, verts: List[Real], tris: List[Int], density: Real,
        stretch_compliance: Real = 0, bend_compliance: Real = 1e-3,
    ) raises:
        if len(verts) % 3 != 0 or len(tris) % 3 != 0 or len(tris) == 0:
            raise Error("MeshCloth: verts must be xyz triples and tris index triples (at least one)")
        if not (density > 0):
            raise Error("MeshCloth: density must be > 0")
        var n = len(verts) // 3
        self.x = List[Vec3](capacity=n)
        for i in range(n):
            self.x.append(Vec3(verts[3 * i], verts[3 * i + 1], verts[3 * i + 2], 0))
        self.prev = self.x.copy()
        self.v = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        var mass = List[Real](length=n, fill=0)
        for t in range(len(tris) // 3):
            var a = tris[3 * t]
            var b = tris[3 * t + 1]
            var c = tris[3 * t + 2]
            if a < 0 or b < 0 or c < 0 or a >= n or b >= n or c >= n:
                raise Error("MeshCloth: triangle index out of range")
            var area = 0.5 * _len(cross(self.x[b] - self.x[a], self.x[c] - self.x[a]))
            for k in [a, b, c]:
                mass[k] += area * density / 3
        self.w = List[Real](capacity=n)
        for i in range(n):
            self.w.append(1 / mass[i] if mass[i] > 0 else 0)
        self.tris = tris.copy()
        self.ea = List[Int]()
        self.eb = List[Int]()
        self.rest = List[Real]()
        self.ba = List[Int]()
        self.bb = List[Int]()
        self.brest = List[Real]()
        self.bedge = List[Int]()
        var first_opp = Dict[Int, Int]()  # edge key -> opposite vertex of its first triangle
        var edge_of = Dict[Int, Int]()
        for t in range(len(tris) // 3):
            for k in range(3):
                var a = tris[3 * t + k]
                var b = tris[3 * t + (k + 1) % 3]
                var o = tris[3 * t + (k + 2) % 3]
                var lo = min(a, b)
                var hi = max(a, b)
                var key = lo * n + hi
                if key in edge_of:
                    var e = edge_of[key]
                    var o1 = first_opp[key]
                    if o1 != o:
                        self.ba.append(o1)
                        self.bb.append(o)
                        self.brest.append(_len(self.x[o] - self.x[o1]))
                        self.bedge.append(e)
                else:
                    edge_of[key] = len(self.ea)
                    first_opp[key] = o
                    self.ea.append(lo)
                    self.eb.append(hi)
                    self.rest.append(_len(self.x[hi] - self.x[lo]))
        self.lam = List[Real](length=len(self.ea), fill=0)
        self.torn = List[Bool](length=len(self.ea), fill=False)
        self.blam = List[Real](length=len(self.ba), fill=0)
        self.stretch_compliance = stretch_compliance
        self.bend_compliance = bend_compliance
        self.break_force = 1e30
        self.damping = 0.999
        self.thickness = 0.01
        self.friction = 0.3
        self.wind = Vec3(0, 0, 0, 0)
        self.drag = 0
        self.substeps = 8
        self.iters = 4
        self.att_vert = List[Int]()
        self.att_body = List[Int]()
        self.att_local = List[Vec3]()

    def vertex_count(self) -> Int:
        return len(self.x)

    def total_mass(self) -> Real:
        var m = Real(0)
        for i in range(len(self.w)):
            if self.w[i] > 0:
                m += 1 / self.w[i]
        return m

    def torn_count(self) -> Int:
        var c = 0
        for t in self.torn:
            if t:
                c += 1
        return c

    def pin(mut self, i: Int) raises:
        if i < 0 or i >= len(self.x):
            raise Error("MeshCloth.pin: vertex out of range")
        self.w[i] = 0

    def attach[B: Body6, BP: BroadPhase](mut self, i: Int, sc: ContactScene6[B, BP], body: Int) raises:
        """Vertex `i` follows the body point it sits on now."""
        if i < 0 or i >= len(self.x) or body < 0 or body >= len(sc.bset.bodies):
            raise Error("MeshCloth.attach: vertex or body out of range")
        self.w[i] = 0
        self.att_vert.append(i)
        self.att_body.append(body)
        self.att_local.append(sc.bset.bodies[body].to_local(self.x[i]))

    # ---- one substep, split so the scene-dependent parts slot in -----------
    def _predict(mut self, h: Real, gravity: Vec3):
        for i in range(len(self.x)):
            self.prev[i] = self.x[i]
            if self.w[i] > 0:
                self.v[i] = self.v[i] + gravity * h
        if self.drag > 0:
            for t in range(len(self.tris) // 3):
                var a = self.tris[3 * t]
                var b = self.tris[3 * t + 1]
                var c = self.tris[3 * t + 2]
                var nn = cross(self.x[b] - self.x[a], self.x[c] - self.x[a])
                var l2 = dot(nn, nn)
                if l2 <= 0:
                    continue
                var ln = sqrt(l2)
                var n = nn / ln
                var area = 0.5 * ln
                var rel = self.wind - (self.v[a] + self.v[b] + self.v[c]) / 3
                var f = n * (self.drag * area * dot(rel, n))
                for k in [a, b, c]:
                    if self.w[k] > 0:
                        self.v[k] = self.v[k] + f * (self.w[k] * h / 3)
        for i in range(len(self.x)):
            if self.w[i] > 0:
                self.x[i] = self.x[i] + self.v[i] * h

    def _constraints(mut self, h: Real):
        for e in range(len(self.lam)):
            self.lam[e] = 0
        for e in range(len(self.blam)):
            self.blam[e] = 0
        var sa = self.stretch_compliance / (h * h)
        var bt = self.bend_compliance / (h * h)
        for _ in range(self.iters):
            # bending first, stretch last: the stiffer stretch constraints
            # get the final word in each sweep (the other order let a stiff
            # bending setting stretch the cloth)
            for e in range(len(self.ba)):
                if self.torn[self.bedge[e]]:
                    continue
                var dl = self._dist(self.ba[e], self.bb[e], self.brest[e], bt, self.blam[e])
                self.blam[e] += dl
            for e in range(len(self.ea)):
                if self.torn[e]:
                    continue
                var dl = self._dist(self.ea[e], self.eb[e], self.rest[e], sa, self.lam[e])
                self.lam[e] += dl
        if self.break_force < 1e30:
            for e in range(len(self.ea)):
                if not self.torn[e] and abs(self.lam[e]) / (h * h) > self.break_force:
                    self.torn[e] = True

    def _dist(mut self, a: Int, b: Int, rest: Real, alpha: Real, lam: Real) -> Real:
        """One XPBD distance projection; returns the lambda increment."""
        var wa = self.w[a]
        var wb = self.w[b]
        var ws = wa + wb
        if ws <= 0:
            return 0
        var d = self.x[b] - self.x[a]
        var l = sqrt(max(dot(d, d), Real(1e-12)))
        var dl = (rest - l - alpha * lam) / (ws + alpha)
        var corr = d * (dl / l)
        self.x[a] = self.x[a] - corr * wa
        self.x[b] = self.x[b] + corr * wb
        return dl

    def _finish(mut self, h: Real):
        for i in range(len(self.x)):
            if self.w[i] > 0:
                self.v[i] = (self.x[i] - self.prev[i]) * (self.damping / h)

    def step[B: Body6, BP: BroadPhase](mut self, sc: ContactScene6[B, BP], dt: Real, gravity: Vec3):
        """Advance `dt` against the scene: attachments follow their bodies,
        vertices collide with every collider (one-way, with friction)."""
        var h = dt / Real(self.substeps)
        var poses = sc.query_poses()
        for _ in range(self.substeps):
            for k in range(len(self.att_vert)):
                self.x[self.att_vert[k]] = sc.bset.bodies[self.att_body[k]].act(self.att_local[k])
            self._predict(h, gravity)
            self._constraints(h)
            for i in range(len(self.x)):
                if self.w[i] == 0:
                    continue
                var hits = overlap_sphere(sc.colliders, poses, self.x[i], self.thickness, QueryFilter.all())
                for q in range(len(hits)):
                    var pr = point_distance(sc.colliders, hits[q], poses[hits[q]], self.x[i])
                    if pr.dist < self.thickness:
                        var push = self.thickness - pr.dist
                        self.x[i] = self.x[i] + pr.normal * push
                        var dx = self.x[i] - self.prev[i]
                        var dt_ = dx - pr.normal * dot(dx, pr.normal)
                        var lt = _len(dt_)
                        if lt > 0:
                            self.x[i] = self.x[i] - dt_ * min(Real(1), self.friction * push / lt)
            self._finish(h)

    # ---- ContinuumSolver (17.55) ----------------------------------------------
    def advance(mut self, dt: Real, gravity: Vec3):
        var h = dt / Real(self.substeps)
        for _ in range(self.substeps):
            self._predict(h, gravity)
            self._constraints(h)
            self._finish(h)

    def _ok(self, i: Int) -> Bool:
        return isfinite(self.x[i][0]) and isfinite(self.x[i][1]) and isfinite(self.x[i][2]) and isfinite(self.v[i][0]) and isfinite(self.v[i][1]) and isfinite(self.v[i][2])

    def health(self) -> ContinuumHealth:
        var bad = 0
        for i in range(len(self.x)):
            if not self._ok(i):
                bad += 1
        return ContinuumHealth(bad, 0, 0)

    def quarantine(mut self) -> Int:
        """Pin a non-finite vertex at a finite edge neighbour (the origin if
        none) with zero velocity."""
        var n = 0
        for i in range(len(self.x)):
            if self._ok(i):
                continue
            var p = Vec3(0, 0, 0, 0)
            for e in range(len(self.ea)):
                var j = self.eb[e] if self.ea[e] == i else (self.ea[e] if self.eb[e] == i else -1)
                if j >= 0 and self._ok(j):
                    p = self.x[j]
                    break
            self.x[i] = p
            self.prev[i] = p
            self.v[i] = Vec3(0, 0, 0, 0)
            self.w[i] = 0
            n += 1
        return n

    def write_state[W: StateWriter](self, mut w: W):
        w.wi(len(self.x))
        for i in range(len(self.x)):
            w.wv(self.x[i])
            w.wv(self.v[i])
            w.wf(self.w[i])
        w.wi(len(self.torn))
        for t in self.torn:
            w.wi(1 if t else 0)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var n = r.ri()
        if n != len(self.x):
            raise Error("MeshCloth.read_state: vertex count differs")
        for i in range(n):
            self.x[i] = r.rv()
            self.prev[i] = self.x[i]
            self.v[i] = r.rv()
            self.w[i] = r.rf()
        var ne = r.ri()
        if ne != len(self.torn):
            raise Error("MeshCloth.read_state: edge count differs")
        for e in range(ne):
            self.torn[e] = r.ri() == 1


def grid_mesh(nx: Int, nz: Int, size_x: Real, size_z: Real, origin: Vec3) -> Tuple[List[Real], List[Int]]:
    """A flat (nx+1) x (nz+1) vertex sheet in the xz plane, two triangles per
    cell with alternating diagonals -- a test / example mesh."""
    var v = List[Real]()
    for j in range(nz + 1):
        for i in range(nx + 1):
            v.append(origin[0] + size_x * Real(i) / Real(nx))
            v.append(origin[1])
            v.append(origin[2] + size_z * Real(j) / Real(nz))
    var t = List[Int]()
    for j in range(nz):
        for i in range(nx):
            var a = j * (nx + 1) + i
            var b = a + 1
            var c = a + nx + 1
            var d = c + 1
            if (i + j) % 2 == 0:
                t.append(a); t.append(c); t.append(b)
                t.append(b); t.append(c); t.append(d)
            else:
                t.append(a); t.append(c); t.append(d)
                t.append(a); t.append(d); t.append(b)
    return (v^, t^)
