"""Multiple-relaxation-time collision for the D3Q19 lattice (ROADMAP 17.60;
d'Humieres et al. 2002).

The populations are mapped to 19 orthogonal moments m = M f: density
rho; energy e = 19 c^2 - 30; energy square eps = (21 c^4 - 53 c^2 + 24) / 2;
momentum j and energy flux q = (5 c^2 - 9) c per axis; the stresses
3 p_xx = 3 c_x^2 - c^2, p_ww = c_y^2 - c_z^2, p_xy, p_yz, p_xz, their
fourth-order partners pi = (3 c^2 - 5) p; and the third-order m_x, m_y,
m_z. Each relaxes toward the moments of the BGK equilibrium at its own
rate: the five stresses at 1/tau (the viscosity, as BGK); momentum at 1/tau
too, so the body force's velocity shift (tau F / rho, as `Lbm.collide`)
adds exactly F; the rest (`s_e`, `s_eps`, `s_q`, `s_pi`, `s_m`) are free --
they set the bulk viscosity and damp the non-hydrodynamic modes, which is
what keeps MRT stable at small viscosity where BGK is not (`test_lbm_mrt`).
With every rate 1/tau it is BGK.

M's rows are orthogonal, so M^-1 = M^T D^-1 with D the rows' squared
norms. `mrt_step(l, m)` is `Lbm.step` with this collision; its own module so
`Lbm` itself is unchanged.
"""

from geometry.vec import Real
from .d3q19 import Q
from .lbm import Lbm, CELL_FLUID


struct Mrt(Movable):
    var m: List[Real]  # 19 x 19, row-major
    var dinv: List[Real]  # 1 / |row|^2
    var s: List[Real]  # relaxation rate per moment

    def __init__(
        out self, l: Lbm, s_e: Real = 1.19, s_eps: Real = 1.4, s_q: Real = 1.2,
        s_pi: Real = 1.4, s_m: Real = 1.98,
    ):
        self.m = List[Real](length=Q * Q, fill=0)
        self.dinv = List[Real](length=Q, fill=0)
        self.s = List[Real](length=Q, fill=0)
        var wv = 1 / l.tau
        for i in range(Q):
            var cx = Real(l.ex[i])
            var cy = Real(l.ey[i])
            var cz = Real(l.ez[i])
            var c2 = cx * cx + cy * cy + cz * cz
            var row: List[Real] = [
                1,
                19 * c2 - 30,
                (21 * c2 * c2 - 53 * c2 + 24) / 2,
                cx, (5 * c2 - 9) * cx,
                cy, (5 * c2 - 9) * cy,
                cz, (5 * c2 - 9) * cz,
                3 * cx * cx - c2, (3 * c2 - 5) * (3 * cx * cx - c2),
                cy * cy - cz * cz, (3 * c2 - 5) * (cy * cy - cz * cz),
                cx * cy, cy * cz, cx * cz,
                (cy * cy - cz * cz) * cx, (cz * cz - cx * cx) * cy, (cx * cx - cy * cy) * cz,
            ]
            for k in range(Q):
                self.m[k * Q + i] = row[k]
        for k in range(Q):
            var d = Real(0)
            for i in range(Q):
                d += self.m[k * Q + i] * self.m[k * Q + i]
            self.dinv[k] = 1 / d
        var rates: List[Real] = [wv, s_e, s_eps, wv, s_q, wv, s_q, wv, s_q, wv, s_pi, wv, s_pi, wv, wv, wv, s_m, s_m, s_m]
        for k in range(Q):
            self.s[k] = rates[k]

    @staticmethod
    def bgk(l: Lbm) -> Mrt:
        """Every rate 1/tau: the BGK collision in moment space."""
        var w = 1 / l.tau
        return Mrt(l, w, w, w, w, w)


def mrt_collide(mut l: Lbm, m: Mrt):
    var n = l.cells()
    var fe = List[Real](length=Q, fill=0)
    var dm = List[Real](length=Q, fill=0)
    for c in range(n):
        if l.flag[c] != CELL_FLUID:
            continue
        var rho = Real(0)
        var ux = Real(0)
        var uy = Real(0)
        var uz = Real(0)
        for i in range(Q):
            var v = l.f[i * n + c]
            rho += v
            ux += v * Real(l.ex[i])
            uy += v * Real(l.ey[i])
            uz += v * Real(l.ez[i])
        if rho <= 0:
            continue
        ux /= rho
        uy /= rho
        uz /= rho
        if l.force_x != 0:
            ux += l.tau * l.force_x / rho
        for i in range(Q):
            fe[i] = l._feq(i, rho, ux, uy, uz)
        # relaxed moment change: s_k (m_k - m_eq_k), then back by M^T D^-1
        for k in range(Q):
            var acc = Real(0)
            for i in range(Q):
                acc += m.m[k * Q + i] * (l.f[i * n + c] - fe[i])
            dm[k] = m.s[k] * acc * m.dinv[k]
        for i in range(Q):
            var acc = Real(0)
            for k in range(Q):
                acc += m.m[k * Q + i] * dm[k]
            l.f[i * n + c] -= acc


def mrt_step(mut l: Lbm, m: Mrt):
    """`Lbm.step` with the MRT collision (constant tau; force_x by the
    velocity shift, force_y / force_z and per-cell forces as `step`)."""
    mrt_collide(l, m)
    if l.force_y != 0 or l.force_z != 0:
        l._force_yz()
    if len(l.cell_force) > 0:
        l._force_cells()
    l.stream()
    l.apply_inlet_outlet()
