"""Morph targets (blend shapes) as sparse deltas (ROADMAP 17.65).

A target stores only the vertices it moves: (vertex index, position delta).
`apply` writes base + sum_t w_t delta_t into `out`; weights are not clamped
(negative and > 1 extrapolate linearly, as in glTF / UE). The order with
skinning is fixed: morph in the bind pose first, then skin the result
(`skin_motor_k(..., morphed, ...)`).

Indices are validated when a target is added (`raise`); `apply` does not
raise except for a weight count that does not match the targets.

Normal deltas: `add_target_n` stores a normal delta next to each position
delta (targets added with `add_target` get zero normal deltas);
`apply_normals` writes normalize(n + sum_t w_t dn_t) (a zero result keeps
the base normal).

In-betweens (`InbetweenMorph`): one target defined by several sparse
shapes at increasing weights 0 < w_1 < ... < w_n (Maya / UE progressive
targets). At weight w the delta is the piecewise-linear interpolation
between the shapes at the bracketing weights, from an implicit zero shape
at w = 0; below 0 and above w_n the first / last segment is extended.
With one shape at w_1 = 1 it is the plain linear target.
"""

from std.math import sqrt
from .vec import Real, Vec3


struct MorphSet(Movable):
    var vertices: Int
    var start: List[Int]  # first delta of each target (len targets + 1)
    var vidx: List[Int]
    var delta: List[Vec3]
    var ndelta: List[Vec3]  # normal delta per entry (zero unless add_target_n)

    def __init__(out self, vertices: Int):
        self.vertices = vertices
        self.start = [0]
        self.vidx = List[Int]()
        self.delta = List[Vec3]()
        self.ndelta = List[Vec3]()

    def targets(self) -> Int:
        return len(self.start) - 1

    def add_target(mut self, idx: List[Int], deltas: List[Vec3]) raises -> Int:
        if len(idx) != len(deltas):
            raise Error("MorphSet.add_target: one delta per index")
        for i in idx:
            if i < 0 or i >= self.vertices:
                raise Error("MorphSet.add_target: vertex index " + String(i) + " out of range")
        for k in range(len(idx)):
            self.vidx.append(idx[k])
            self.delta.append(deltas[k])
            self.ndelta.append(Vec3(0, 0, 0, 0))
        self.start.append(len(self.vidx))
        return self.targets() - 1

    def add_target_n(mut self, idx: List[Int], deltas: List[Vec3], ndeltas: List[Vec3]) raises -> Int:
        """As `add_target`, with a normal delta per index."""
        if len(ndeltas) != len(idx):
            raise Error("MorphSet.add_target_n: one normal delta per index")
        var t = self.add_target(idx, deltas)
        for k in range(len(ndeltas)):
            self.ndelta[self.start[t] + k] = ndeltas[k]
        return t

    def apply_normals(self, base_n: List[Vec3], weights: List[Real], mut out: List[Vec3]) raises:
        if len(weights) != self.targets() or len(base_n) != self.vertices or len(out) < self.vertices:
            raise Error("MorphSet.apply_normals: one weight per target, base and out sized to the vertices")
        for i in range(self.vertices):
            out[i] = base_n[i]
        for t in range(self.targets()):
            var wt = weights[t]
            if wt == 0:
                continue
            for k in range(self.start[t], self.start[t + 1]):
                out[self.vidx[k]] = out[self.vidx[k]] + self.ndelta[k] * wt
        for i in range(self.vertices):
            var n = out[i]
            var l = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2])
            out[i] = n * (1 / l) if l > 0 else base_n[i]

    @staticmethod
    def from_shape(base: List[Vec3], shape: List[Vec3], eps: Real = 0) raises -> MorphSet:
        """A one-target set holding shape - base wherever it differs by more
        than `eps` on any axis."""
        if len(base) != len(shape):
            raise Error("MorphSet.from_shape: shape and base differ in length")
        var m = MorphSet(len(base))
        var idx = List[Int]()
        var d = List[Vec3]()
        for i in range(len(base)):
            var dd = shape[i] - base[i]
            if abs(dd[0]) > eps or abs(dd[1]) > eps or abs(dd[2]) > eps:
                idx.append(i)
                d.append(dd)
        _ = m.add_target(idx, d)
        return m^

    def apply(self, base: List[Vec3], weights: List[Real], mut out: List[Vec3]) raises:
        if len(weights) != self.targets() or len(base) != self.vertices or len(out) < self.vertices:
            raise Error("MorphSet.apply: one weight per target, base and out sized to the vertices")
        for i in range(self.vertices):
            out[i] = base[i]
        for t in range(self.targets()):
            var wt = weights[t]
            if wt == 0:
                continue
            for k in range(self.start[t], self.start[t + 1]):
                out[self.vidx[k]] = out[self.vidx[k]] + self.delta[k] * wt


struct InbetweenMorph(Movable):
    """One progressive target: sparse shapes at increasing weights (module
    note). Shapes are stored densely over the union of their indices."""

    var vertices: Int
    var at: List[Real]  # the shapes' weights, increasing, > 0
    var vidx: List[Int]  # union of indices
    var delta: List[Vec3]  # [shape * len(vidx) + k]

    def __init__(out self, vertices: Int):
        self.vertices = vertices
        self.at = List[Real]()
        self.vidx = List[Int]()
        self.delta = List[Vec3]()

    def shapes(self) -> Int:
        return len(self.at)

    def add_shape(mut self, weight: Real, idx: List[Int], deltas: List[Vec3]) raises:
        if not (weight > 0) or (len(self.at) > 0 and not (weight > self.at[len(self.at) - 1])):
            raise Error("InbetweenMorph.add_shape: weights must be > 0 and increasing")
        if len(idx) != len(deltas):
            raise Error("InbetweenMorph.add_shape: one delta per index")
        for i in idx:
            if i < 0 or i >= self.vertices:
                raise Error("InbetweenMorph.add_shape: vertex index " + String(i) + " out of range")
        # grow the union, padding earlier shapes with zero deltas
        var n_old = len(self.vidx)
        var pos = Dict[Int, Int]()
        for k in range(n_old):
            pos[self.vidx[k]] = k
        for i in idx:
            if i not in pos:
                pos[i] = len(self.vidx)
                self.vidx.append(i)
        var n = len(self.vidx)
        var grown = List[Vec3]()
        for s in range(len(self.at)):
            for k in range(n):
                grown.append(self.delta[s * n_old + k] if k < n_old else Vec3(0, 0, 0, 0))
        for _ in range(n):
            grown.append(Vec3(0, 0, 0, 0))
        var base = len(self.at) * n
        for k in range(len(idx)):
            grown[base + pos[idx[k]]] = deltas[k]
        self.delta = grown^
        self.at.append(weight)

    def apply(self, base: List[Vec3], weight: Real, mut out: List[Vec3]) raises:
        """Write base + the interpolated delta at `weight` into out."""
        if len(self.at) == 0 or len(base) != self.vertices or len(out) < self.vertices:
            raise Error("InbetweenMorph.apply: needs a shape; base and out sized to the vertices")
        for i in range(self.vertices):
            out[i] = base[i]
        if weight == 0:
            return
        var n = len(self.vidx)
        # segment [lo, hi] with shape -1 = the zero shape at weight 0
        var hi = 0
        while hi < len(self.at) - 1 and weight > self.at[hi]:
            hi += 1
        if weight <= 0:
            hi = 0
        var lo = hi - 1
        var w_lo = self.at[lo] if lo >= 0 else Real(0)
        var t = (weight - w_lo) / (self.at[hi] - w_lo)
        for k in range(n):
            var d_lo = self.delta[lo * n + k] if lo >= 0 else Vec3(0, 0, 0, 0)
            var d_hi = self.delta[hi * n + k]
            out[self.vidx[k]] = out[self.vidx[k]] + d_lo + (d_hi - d_lo) * t
