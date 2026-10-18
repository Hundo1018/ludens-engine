"""Cloth and lattice air as `CoupledPart`s (ROADMAP 17.61).

`ClothAir` couples a `MeshCloth` to an `Lbm` with its own fixed schedule.
These two parts put the same exchange under `Coupler`, so cloth <-> air
gets the coupler's schemes, substeps, conservation record and snapshot:

  * `ClothPart` (A) receives the air velocity at each vertex (3 per
    vertex, m/s), applies the normal drag of `ClothAir` (implicit along
    the area-weighted normal; pinned vertices feel F = k A n (n . u)) and
    steps the cloth. It sends, per vertex, its position now (where the air
    samples next), its position at the drag (where the impulse goes) and
    the drag impulse J (9 per vertex).
  * `AirPart` (B) receives that, adds -J (split over `ratio` substeps) to
    the 8 lattice cells around each drag position with trilinear weights
    as lattice momentum (`Lbm.add_cell_force`), steps the lattice (one
    lattice step = `dt_lat` seconds, which must equal the coupler's
    substep) and sends the air velocity at the cloth's current positions.

`impulse()` is the momentum (N s, 3 components) each received in its last
advance; with `EXPLICIT` the two cancel to rounding, and with ratio 1 the
pair reproduces `ClothAir.step` bit for bit (`test_cloth_air_parts`).
`INTERP` interpolates the received data between steps, impulses
included, so it does not conserve momentum here; the coupler's
`imbalance` shows by how much.

`BallPart` is a rigid ball with the same per-point interface; with
`coupler.Both` a cloth and a ball share one lattice (three solvers, one
coupler, one imbalance per step).
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, cross, dot
from fluid.lbm import Lbm
from .cloth import MeshCloth
from .cloth_air import lattice_corners, lattice_velocity
from .coupler import CoupledPart, write_reals, read_reals
from .state_io import StateWriter, StateReader


def _vec(d: List[Real], i: Int) -> Vec3:
    return Vec3(d[3 * i], d[3 * i + 1], d[3 * i + 2], 0)


struct ClothPart(CoupledPart):
    var cloth: MeshCloth
    var k: Real  # drag coefficient, kg / (m^2 s)
    var gravity: Vec3
    var air_u: List[Real]  # received air velocity per vertex
    var x_drag: List[Vec3]  # positions where the last drag acted
    var jv: List[Vec3]  # last drag impulse per vertex
    var received: Vec3  # sum of jv
    var total: Vec3  # since construction
    var _x: List[Vec3]
    var _prev: List[Vec3]
    var _v: List[Vec3]
    var _xd: List[Vec3]
    var _jv: List[Vec3]

    def __init__(out self, var cloth: MeshCloth, k: Real, gravity: Vec3) raises:
        if not (k >= 0):
            raise Error("ClothPart: k >= 0")
        var n = len(cloth.x)
        self.k = k
        self.gravity = gravity
        self.air_u = List[Real](length=3 * n, fill=0)
        self.x_drag = cloth.x.copy()
        self.jv = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        self.received = Vec3(0, 0, 0, 0)
        self.total = Vec3(0, 0, 0, 0)
        self._x = List[Vec3]()
        self._prev = List[Vec3]()
        self._v = List[Vec3]()
        self._xd = List[Vec3]()
        self._jv = List[Vec3]()
        self.cloth = cloth^

    def advance(mut self, dt: Real) raises:
        var n = len(self.cloth.x)
        var area = List[Real](length=n, fill=0)
        var normal = List[Vec3](length=n, fill=Vec3(0, 0, 0, 0))
        for t in range(len(self.cloth.tris) // 3):
            var a = self.cloth.tris[3 * t]
            var b = self.cloth.tris[3 * t + 1]
            var c = self.cloth.tris[3 * t + 2]
            var nn = cross(self.cloth.x[b] - self.cloth.x[a], self.cloth.x[c] - self.cloth.x[a])
            var ar = 0.5 * sqrt(dot(nn, nn)) / 3
            for v in [a, b, c]:
                area[v] += ar
                normal[v] = normal[v] + nn
        self.received = Vec3(0, 0, 0, 0)
        for i in range(n):
            self.x_drag[i] = self.cloth.x[i]
            self.jv[i] = Vec3(0, 0, 0, 0)
            var nl = sqrt(dot(normal[i], normal[i]))
            if nl <= 0 or area[i] <= 0:
                continue
            var nrm = normal[i] / nl
            var u = _vec(self.air_u, i)
            var j: Vec3
            if self.cloth.w[i] > 0:
                var m = 1 / self.cloth.w[i]
                var a = self.k * area[i] * dt / m
                var vn = dot(self.cloth.v[i], nrm)
                var vn_new = (vn + a * dot(u, nrm)) / (1 + a)
                j = nrm * (m * (vn_new - vn))
                self.cloth.v[i] = self.cloth.v[i] + nrm * (vn_new - vn)
            else:
                j = nrm * (self.k * area[i] * dt * dot(u - self.cloth.v[i], nrm))
            self.jv[i] = j
            self.received = self.received + j
        self.total = self.total + self.received
        self.cloth.advance(dt, self.gravity)

    def send(self) -> List[Real]:
        var n = len(self.cloth.x)
        var out = List[Real](capacity=9 * n)
        for i in range(n):
            for c in range(3):
                out.append(self.cloth.x[i][c])
            for c in range(3):
                out.append(self.x_drag[i][c])
            for c in range(3):
                out.append(self.jv[i][c])
        return out^

    def recv(mut self, data: List[Real]):
        self.air_u = data.copy()

    def impulse(self) -> List[Real]:
        return [self.received[0], self.received[1], self.received[2]]

    def save(mut self):
        self._x = self.cloth.x.copy()
        self._prev = self.cloth.prev.copy()
        self._v = self.cloth.v.copy()
        self._xd = self.x_drag.copy()
        self._jv = self.jv.copy()

    def restore(mut self):
        self.cloth.x = self._x.copy()
        self.cloth.prev = self._prev.copy()
        self.cloth.v = self._v.copy()
        self.x_drag = self._xd.copy()
        self.jv = self._jv.copy()

    def write_state[W: StateWriter](self, mut w: W):
        self.cloth.write_state(w)
        w.wi(len(self.x_drag))
        for i in range(len(self.x_drag)):
            w.wv(self.cloth.prev[i])
            w.wv(self.x_drag[i])
            w.wv(self.jv[i])
        write_reals(w, self.air_u)
        w.wv(self.received)
        w.wv(self.total)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.cloth.read_state(r)
        var n = r.ri()
        if n != len(self.x_drag):
            raise Error("ClothPart.read_state: vertex count differs")
        for i in range(n):
            self.cloth.prev[i] = r.rv()
            self.x_drag[i] = r.rv()
            self.jv[i] = r.rv()
        self.air_u = read_reals(r)
        self.received = r.rv()
        self.total = r.rv()


struct AirPart(CoupledPart):
    var lbm: Lbm
    var origin: Vec3
    var dx: Real
    var dt_lat: Real  # seconds per lattice step = the coupler's substep
    var rho: Real
    var ratio: Int  # lattice steps per coupling step (the J split)
    var pos: List[Vec3]  # where the air is sampled for the cloth
    var x_drag: List[Vec3]
    var jv: List[Vec3]
    var received: Vec3
    var total: Vec3
    var _f: List[Real]
    var _fx: Real
    var _fy: Real
    var _fz: Real

    def __init__(out self, var lbm: Lbm, origin: Vec3, dx: Real, dt_lat: Real, rho: Real, ratio: Int, cloth_x: List[Vec3]) raises:
        if not (dx > 0) or not (dt_lat > 0) or not (rho > 0) or ratio < 1:
            raise Error("AirPart: dx, dt_lat, rho > 0 and ratio >= 1")
        self.origin = origin
        self.dx = dx
        self.dt_lat = dt_lat
        self.rho = rho
        self.ratio = ratio
        self.pos = cloth_x.copy()
        self.x_drag = cloth_x.copy()
        self.jv = List[Vec3](length=len(cloth_x), fill=Vec3(0, 0, 0, 0))
        self.received = Vec3(0, 0, 0, 0)
        self.total = Vec3(0, 0, 0, 0)
        self._f = List[Real]()
        self._fx = 0
        self._fy = 0
        self._fz = 0
        self.lbm = lbm^

    def advance(mut self, dt: Real) raises:
        if abs(dt - self.dt_lat) > 1e-6 * self.dt_lat:
            raise Error("AirPart.advance: the substep must equal dt_lat (one lattice step)")
        self.lbm.clear_cell_force()
        var to_lat = self.dt_lat / (self.rho * self.dx * self.dx * self.dx * self.dx)
        self.received = Vec3(0, 0, 0, 0)
        for i in range(len(self.jv)):
            var j = self.jv[i] if self.ratio == 1 else self.jv[i] * (1 / Real(self.ratio))
            if j[0] == 0 and j[1] == 0 and j[2] == 0:
                continue
            self.received = self.received - j
            var cw = lattice_corners(self.lbm, self.origin, self.dx, self.x_drag[i])
            var cs = cw[0].copy()
            var ws = cw[1].copy()
            for q in range(8):
                self.lbm.add_cell_force(cs[q], j * (-to_lat * ws[q]))
        self.total = self.total + self.received
        self.lbm.step()

    def send(self) -> List[Real]:
        var out = List[Real](capacity=3 * len(self.pos))
        for p in self.pos:
            var u = lattice_velocity(self.lbm, self.origin, self.dx, self.dt_lat, p)
            for c in range(3):
                out.append(u[c])
        return out^

    def recv(mut self, data: List[Real]):
        for i in range(len(self.pos)):
            self.pos[i] = Vec3(data[9 * i], data[9 * i + 1], data[9 * i + 2], 0)
            self.x_drag[i] = Vec3(data[9 * i + 3], data[9 * i + 4], data[9 * i + 5], 0)
            self.jv[i] = Vec3(data[9 * i + 6], data[9 * i + 7], data[9 * i + 8], 0)

    def impulse(self) -> List[Real]:
        return [self.received[0], self.received[1], self.received[2]]

    def save(mut self):
        self._f = self.lbm.f.copy()
        self._fx = self.lbm.fx
        self._fy = self.lbm.fy
        self._fz = self.lbm.fz

    def restore(mut self):
        self.lbm.f = self._f.copy()
        self.lbm.fx = self._fx
        self.lbm.fy = self._fy
        self.lbm.fz = self._fz

    def write_state[W: StateWriter](self, mut w: W):
        """The populations, the measured solid force and the received
        interface data (moving solids and per-cell tau are configuration,
        not written)."""
        write_reals(w, self.lbm.f)
        w.wf(self.lbm.fx)
        w.wf(self.lbm.fy)
        w.wf(self.lbm.fz)
        w.wi(len(self.pos))
        for i in range(len(self.pos)):
            w.wv(self.pos[i])
            w.wv(self.x_drag[i])
            w.wv(self.jv[i])
        w.wv(self.received)
        w.wv(self.total)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        var f = read_reals(r)
        if len(f) != len(self.lbm.f):
            raise Error("AirPart.read_state: lattice size differs")
        self.lbm.f = f^
        self.lbm.fx = r.rf()
        self.lbm.fy = r.rf()
        self.lbm.fz = r.rf()
        var n = r.ri()
        if n != len(self.pos):
            raise Error("AirPart.read_state: vertex count differs")
        for i in range(n):
            self.pos[i] = r.rv()
            self.x_drag[i] = r.rv()
            self.jv[i] = r.rv()
        self.received = r.rv()
        self.total = r.rv()


struct BallPart(CoupledPart):
    """A rigid ball in the air as one immersed point at its centre: linear
    drag F = c (u - v), integrated implicitly, v <- (v + a u) / (1 + a),
    a = c dt / m, then gravity and the position update (symplectic Euler).
    Same interface as `ClothPart` for one point (receives 3, sends 9), so
    it plugs into `AirPart` and, with `Both`, shares a lattice with a
    cloth. Translation only: a drag at the centre exerts no torque."""

    var x: Vec3
    var v: Vec3
    var m: Real
    var c: Real  # drag coefficient, kg / s
    var gravity: Vec3
    var air_u: Vec3
    var x_drag: Vec3
    var j: Vec3
    var total: Vec3
    var _x: Vec3
    var _v: Vec3
    var _xd: Vec3
    var _j: Vec3

    def __init__(out self, x: Vec3, m: Real, c: Real, gravity: Vec3) raises:
        if not (m > 0) or not (c >= 0):
            raise Error("BallPart: m > 0 and c >= 0")
        self.x = x
        self.v = Vec3(0, 0, 0, 0)
        self.m = m
        self.c = c
        self.gravity = gravity
        self.air_u = Vec3(0, 0, 0, 0)
        self.x_drag = x
        self.j = Vec3(0, 0, 0, 0)
        self.total = Vec3(0, 0, 0, 0)
        self._x = x
        self._v = self.v
        self._xd = x
        self._j = self.j

    def advance(mut self, dt: Real) raises:
        var a = self.c * dt / self.m
        var v_new = (self.v + self.air_u * a) * (1 / (1 + a))
        self.j = (v_new - self.v) * self.m
        self.total = self.total + self.j
        self.x_drag = self.x
        self.v = v_new + self.gravity * dt
        self.x = self.x + self.v * dt

    def send(self) -> List[Real]:
        return [
            self.x[0], self.x[1], self.x[2],
            self.x_drag[0], self.x_drag[1], self.x_drag[2],
            self.j[0], self.j[1], self.j[2],
        ]

    def recv(mut self, data: List[Real]):
        self.air_u = Vec3(data[0], data[1], data[2], 0)

    def impulse(self) -> List[Real]:
        return [self.j[0], self.j[1], self.j[2]]

    def save(mut self):
        self._x = self.x
        self._v = self.v
        self._xd = self.x_drag
        self._j = self.j

    def restore(mut self):
        self.x = self._x
        self.v = self._v
        self.x_drag = self._xd
        self.j = self._j

    def write_state[W: StateWriter](self, mut w: W):
        w.wv(self.x)
        w.wv(self.v)
        w.wv(self.air_u)
        w.wv(self.x_drag)
        w.wv(self.j)
        w.wv(self.total)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.x = r.rv()
        self.v = r.rv()
        self.air_u = r.rv()
        self.x_drag = r.rv()
        self.j = r.rv()
        self.total = r.rv()
