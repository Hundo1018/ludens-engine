"""Experiment R2 — discrete exterior calculus (DEC) on a triangulated grid.

Cochains live on mesh elements — 0-forms on vertices, 1-forms on edges,
2-forms on faces — and the exterior derivative `d` is the (signed) incidence
map. Two structural facts are checked numerically:

  1. d∘d = 0 — the boundary of a boundary vanishes (exactness of the complex),
     the discrete counterpart of curl(grad f) = 0.
  2. Discrete Stokes: Σ_faces (d1 ω) = circulation of ω around the grid
     boundary (interior edge contributions cancel in pairs).

Then heat flows by the graph Laplacian L = d0ᵀ d0 (uniform Hodge star):
diffusion smooths a hot spot while conserving total heat.

Run: pixi run mojo run -I build experiments/exp_dec.mojo
"""

from scheduler.rng import SplitMix64, Rng
from geometry.vec import Real

comptime NV = 5  # vertices per side -> (NV-1)^2 * 2 triangles


struct Mesh(Movable, ImplicitlyDeletable):
    """Triangulated NV×NV grid: vertices, oriented edges, oriented faces."""

    var edges: List[Tuple[Int, Int]]  # (a, b) oriented a -> b
    var faces: List[Tuple[Int, Int, Int]]  # CCW triangles

    def __init__(out self):
        self.edges = List[Tuple[Int, Int]]()
        self.faces = List[Tuple[Int, Int, Int]]()
        # grid edges: right + up + diagonal per cell (consistent orientation)
        for y in range(NV):
            for x in range(NV):
                var v = y * NV + x
                if x + 1 < NV:
                    self.edges.append((v, v + 1))
                if y + 1 < NV:
                    self.edges.append((v, v + NV))
                if x + 1 < NV and y + 1 < NV:
                    self.edges.append((v, v + NV + 1))  # diagonal
        for y in range(NV - 1):
            for x in range(NV - 1):
                var v = y * NV + x
                # two CCW triangles per cell, sharing the diagonal
                self.faces.append((v, v + 1, v + NV + 1))
                self.faces.append((v, v + NV + 1, v + NV))

    def edge_index(self, a: Int, b: Int) -> Tuple[Int, Int]:
        """(index, sign): sign −1 when the stored orientation is b→a."""
        for i in range(len(self.edges)):
            if self.edges[i][0] == a and self.edges[i][1] == b:
                return (i, 1)
            if self.edges[i][0] == b and self.edges[i][1] == a:
                return (i, -1)
        return (-1, 0)


def d0(m: Mesh, f: List[Real]) -> List[Real]:
    """Exterior derivative of a 0-form: (d0 f)(a→b) = f(b) − f(a)."""
    var out = List[Real]()
    for i in range(len(m.edges)):
        out.append(f[m.edges[i][1]] - f[m.edges[i][0]])
    return out^

def d1(m: Mesh, w: List[Real]) -> List[Real]:
    """Exterior derivative of a 1-form: circulation around each face."""
    var out = List[Real]()
    for i in range(len(m.faces)):
        var a = m.faces[i][0]
        var b = m.faces[i][1]
        var c = m.faces[i][2]
        var s = Real(0)
        for pair in [(a, b), (b, c), (c, a)]:
            var es = m.edge_index(pair[0], pair[1])
            s += Real(es[1]) * w[es[0]]
        out.append(s)
    return out^


def main():
    var m = Mesh()
    var rng = SplitMix64.seeded(5)
    print("== DEC on a", NV, "x", NV, "grid:", len(m.edges), "edges,", len(m.faces), "faces ==")

    # --- 1. d∘d = 0 on a random 0-form ---
    var f = List[Real]()
    for _ in range(NV * NV):
        f.append(Real(rng.next_f32()) * 2 - 1)
    var ddf = d1(m, d0(m, f))
    var worst = Real(0)
    for i in range(len(ddf)):
        if abs(ddf[i]) > worst:
            worst = abs(ddf[i])
    print("max |d(d f)| over all faces (expect 0):", worst)

    # --- 2. discrete Stokes: Σ d1(ω) == boundary circulation of ω ---
    var w = List[Real]()
    for _ in range(len(m.edges)):
        w.append(Real(rng.next_f32()) * 2 - 1)
    var total = Real(0)
    var dw = d1(m, w)
    for i in range(len(dw)):
        total += dw[i]
    # boundary loop CCW: bottom, right, top (reversed), left (reversed)
    var circ = Real(0)
    for x in range(NV - 1):
        var es = m.edge_index(x, x + 1)
        circ += Real(es[1]) * w[es[0]]
    for y in range(NV - 1):
        var es = m.edge_index((NV - 1) + y * NV, (NV - 1) + (y + 1) * NV)
        circ += Real(es[1]) * w[es[0]]
    for x in range(NV - 1):
        var v = NV * (NV - 1) + (NV - 1 - x)
        var es = m.edge_index(v, v - 1)
        circ += Real(es[1]) * w[es[0]]
    for y in range(NV - 1):
        var v = (NV - 1 - y) * NV
        var es = m.edge_index(v, v - NV)
        circ += Real(es[1]) * w[es[0]]
    print("Stokes: Σ_faces dω =", total, " boundary circulation =", circ)

    # --- 3. heat flow by L = d0ᵀ d0, conserving total heat ---
    var u = List[Real]()
    for _ in range(NV * NV):
        u.append(Real(0))
    u[(NV // 2) * NV + NV // 2] = 100  # hot spot in the middle
    comptime DT = Real(0.05)
    for step in range(60):
        var du = d0(m, u)
        var lap = List[Real]()
        for _ in range(NV * NV):
            lap.append(Real(0))
        for i in range(len(m.edges)):
            # diffusion: each vertex relaxes toward its neighbours (−L u)
            lap[m.edges[i][0]] += du[i]
            lap[m.edges[i][1]] -= du[i]
        for i in range(NV * NV):
            u[i] += DT * lap[i]
        if step % 20 == 19:
            var tot = Real(0)
            var peak = Real(0)
            for i in range(NV * NV):
                tot += u[i]
                if u[i] > peak:
                    peak = u[i]
            print("  step", step + 1, ": total heat =", tot, " peak =", peak)
