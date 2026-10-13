"""Morph targets (blend shapes) as sparse deltas (ROADMAP 17.65).

A target stores only the vertices it moves: (vertex index, position delta).
`apply` writes base + sum_t w_t delta_t into `out`; weights are not clamped
(negative and > 1 extrapolate linearly, as in glTF / UE). The order with
skinning is fixed: morph in the bind pose first, then skin the result
(`skin_motor_k(..., morphed, ...)`).

Indices are validated when a target is added (`raise`); `apply` does not
raise except for a weight count that does not match the targets.
"""

from .vec import Real, Vec3


struct MorphSet(Movable):
    var vertices: Int
    var start: List[Int]  # first delta of each target (len targets + 1)
    var vidx: List[Int]
    var delta: List[Vec3]

    def __init__(out self, vertices: Int):
        self.vertices = vertices
        self.start = [0]
        self.vidx = List[Int]()
        self.delta = List[Vec3]()

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
        self.start.append(len(self.vidx))
        return self.targets() - 1

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
