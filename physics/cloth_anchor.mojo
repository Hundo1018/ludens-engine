"""Cloth attached to a rigid body, through `Coupler` (ROADMAP 17.61).

`MeshCloth.attach` holds an attached vertex on its body point by
kinematics: the body never feels the cloth's weight or tension through
the attachment. These two parts put the attachment under `Coupler` with
a reaction:

  * `ClothAnchorPart` (A): a `MeshCloth` whose attached vertices stay free
    (they keep their mass). It receives each attachment point's target
    (where the body point is now), steps the cloth, then welds every
    attached vertex to its target: dx = target - x, x <- target,
    v <- v + dx / dt. The impulse that weld takes is J = m dx / dt, the
    impulse the cloth's own constraints (weight, stretch, bending) put
    on the attachment. It sends J per point.
  * `AnchorPart` (B): a translation-only rigid body of mass M with
    attachment points at fixed offsets r_i. It receives J per point, moves
    by -sum(J) / ratio per substep, and sends each point's target
    x + r_i (3 per point).

`impulse()` is the impulse each side received in its last advance; with
`EXPLICIT` the pair sums to zero exactly, so the coupler's imbalance is
rounding, and momentum of cloth + body changes only by gravity. Targets
come from the body's position at the start of the step, so the cloth
sees the body one step late; `test_cloth_anchor` measures what that
costs in free fall.
"""

from geometry.vec import Real, Vec3
from .cloth import MeshCloth
from .coupler import CoupledPart, write_reals, read_reals
from .state_io import StateWriter, StateReader


struct ClothAnchorPart(CoupledPart):
    var cloth: MeshCloth
    var gravity: Vec3
    var att: List[Int]  # attached vertex, one per attachment point
    var target: List[Vec3]  # received: where each point is now
    var jv: List[Vec3]  # impulse the weld took at each point, last advance
    var received: Vec3  # sum of jv (impulse on the cloth, last advance)
    var total: Vec3  # since construction
    var _x: List[Vec3]
    var _prev: List[Vec3]
    var _v: List[Vec3]
    var _target: List[Vec3]
    var _jv: List[Vec3]

    def __init__(out self, var cloth: MeshCloth, att: List[Int], gravity: Vec3) raises:
        var n = len(cloth.x)
        for k in range(len(att)):
            var i = att[k]
            if i < 0 or i >= n:
                raise Error("ClothAnchorPart: attached vertex out of range")
            if not (cloth.w[i] > 0):
                raise Error("ClothAnchorPart: attached vertex needs mass (w > 0)")
        self.gravity = gravity
        self.att = att.copy()
        self.target = List[Vec3](capacity=len(att))
        self.jv = List[Vec3](length=len(att), fill=Vec3(0, 0, 0, 0))
        for k in range(len(att)):
            self.target.append(cloth.x[att[k]])
        self.received = Vec3(0, 0, 0, 0)
        self.total = Vec3(0, 0, 0, 0)
        self._x = List[Vec3]()
        self._prev = List[Vec3]()
        self._v = List[Vec3]()
        self._target = List[Vec3]()
        self._jv = List[Vec3]()
        self.cloth = cloth^

    def advance(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("ClothAnchorPart.advance: dt > 0")
        self.cloth.advance(dt, self.gravity)
        self.received = Vec3(0, 0, 0, 0)
        for k in range(len(self.att)):
            var i = self.att[k]
            var dx = self.target[k] - self.cloth.x[i]
            self.cloth.x[i] = self.target[k]
            self.cloth.v[i] = self.cloth.v[i] + dx / dt
            self.jv[k] = dx * ((1 / self.cloth.w[i]) / dt)
            self.received = self.received + self.jv[k]
        self.total = self.total + self.received

    def send(self) -> List[Real]:
        var out = List[Real](capacity=3 * len(self.att))
        for k in range(len(self.att)):
            for c in range(3):
                out.append(self.jv[k][c])
        return out^

    def recv(mut self, data: List[Real]):
        if len(data) != 3 * len(self.att):
            return
        for k in range(len(self.att)):
            self.target[k] = Vec3(data[3 * k], data[3 * k + 1], data[3 * k + 2], 0)

    def impulse(self) -> List[Real]:
        return [self.received[0], self.received[1], self.received[2]]

    def save(mut self):
        self._x = self.cloth.x.copy()
        self._prev = self.cloth.prev.copy()
        self._v = self.cloth.v.copy()
        self._target = self.target.copy()
        self._jv = self.jv.copy()

    def restore(mut self):
        self.cloth.x = self._x.copy()
        self.cloth.prev = self._prev.copy()
        self.cloth.v = self._v.copy()
        self.target = self._target.copy()
        self.jv = self._jv.copy()

    def write_state[W: StateWriter](self, mut w: W):
        self.cloth.write_state(w)
        w.wi(len(self.att))
        for k in range(len(self.att)):
            w.wv(self.target[k])
            w.wv(self.jv[k])
        w.wv(self.received)
        w.wv(self.total)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.cloth.read_state(r)
        var n = r.ri()
        if n != len(self.att):
            raise Error("ClothAnchorPart.read_state: attachment count differs")
        for k in range(n):
            self.target[k] = r.rv()
            self.jv[k] = r.rv()
        self.received = r.rv()
        self.total = r.rv()


struct AnchorPart(CoupledPart):
    var x: Vec3
    var v: Vec3
    var m: Real
    var r: List[Vec3]  # attachment point offsets from x (fixed, world axes)
    var gravity: Vec3
    var ratio: Int  # cloth steps per anchor substep
    var jin: List[Real]  # received: impulse on the cloth per point (3 each)
    var j: Vec3  # impulse the body took in its last advance
    var total: Vec3  # since construction
    var _x: Vec3
    var _v: Vec3
    var _j: Vec3

    def __init__(out self, x: Vec3, m: Real, var r: List[Vec3], gravity: Vec3, ratio: Int = 1) raises:
        if not (m > 0):
            raise Error("AnchorPart: m > 0")
        if ratio < 1:
            raise Error("AnchorPart: ratio >= 1")
        self.x = x
        self.v = Vec3(0, 0, 0, 0)
        self.m = m
        self.r = r^
        self.gravity = gravity
        self.ratio = ratio
        self.jin = List[Real](length=3 * len(self.r), fill=0)
        self.j = Vec3(0, 0, 0, 0)
        self.total = Vec3(0, 0, 0, 0)
        self._x = x
        self._v = self.v
        self._j = self.j

    def advance(mut self, dt: Real) raises:
        if not (dt > 0):
            raise Error("AnchorPart.advance: dt > 0")
        var h = dt
        var sum = Vec3(0, 0, 0, 0)
        for k in range(len(self.r)):
            sum = sum + Vec3(self.jin[3 * k], self.jin[3 * k + 1], self.jin[3 * k + 2], 0)
        self.j = sum * (-1 / Real(self.ratio))
        self.total = self.total + self.j
        self.v = self.v + self.j / self.m + self.gravity * h
        self.x = self.x + self.v * h

    def send(self) -> List[Real]:
        var out = List[Real](capacity=3 * len(self.r))
        for k in range(len(self.r)):
            var p = self.x + self.r[k]
            out.append(p[0])
            out.append(p[1])
            out.append(p[2])
        return out^

    def recv(mut self, data: List[Real]):
        if len(data) != 3 * len(self.r):
            return
        self.jin = data.copy()

    def impulse(self) -> List[Real]:
        return [self.j[0], self.j[1], self.j[2]]

    def save(mut self):
        self._x = self.x
        self._v = self.v
        self._j = self.j

    def restore(mut self):
        self.x = self._x
        self.v = self._v
        self.j = self._j

    def write_state[W: StateWriter](self, mut w: W):
        w.wv(self.x)
        w.wv(self.v)
        w.wi(len(self.r))
        write_reals(w, self.jin)
        w.wv(self.j)
        w.wv(self.total)

    def read_state[R: StateReader](mut self, mut r: R) raises:
        self.x = r.rv()
        self.v = r.rv()
        if r.ri() != len(self.r):
            raise Error("AnchorPart.read_state: point count differs")
        self.jin = read_reals(r)
        self.j = r.rv()
        self.total = r.rv()
