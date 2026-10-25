"""APIC transfers for `FlipWater2` (ROADMAP 17.60; Jiang et al. 2015).

`apic_step(w, st, dt)` is `FlipWater2.step` with steps 2 and 5 (particles
to faces and back) as affine transfers. `ApicState` carries each particle's
velocity gradients c_u, c_v; to the grid a particle splats
pu + c_u . (x_face - x_p) (v alike), and back it takes pu = sum w u and
c_u = sum u grad w (the form for bilinear weights). No FLIP / PIC blend:
the transfer keeps angular momentum without FLIP's noise
(`test_flip_apic`). Its own module: adding the APIC fields and methods to
`FlipWater2` moved `test_flip`'s last digits, so the FLIP code stays as it
was.
"""

from std.math import floor
from geometry.vec import Real
from .flip import FlipWater2


struct ApicState(Movable):
    var cux: List[Real]  # d(pu)/dx, d(pu)/dy, d(pv)/dx, d(pv)/dy per particle
    var cuy: List[Real]
    var cvx: List[Real]
    var cvy: List[Real]

    def __init__(out self):
        self.cux = List[Real]()
        self.cuy = List[Real]()
        self.cvx = List[Real]()
        self.cvy = List[Real]()


def _splat_affine(
    mut f: List[Real], mut wsum: List[Real], w: Int, h: Int, dx: Real, x: Real, y: Real,
    ox: Real, oy: Real, val: Real, cx: Real, cy: Real,
):
    """`_splat` of val + (cx, cy) . (x_node - x_p)."""
    var gx = min(max(x / dx - ox, Real(0)), Real(w - 1) - 1e-4)
    var gy = min(max(y / dx - oy, Real(0)), Real(h - 1) - 1e-4)
    var i = Int(floor(gx))
    var j = Int(floor(gy))
    var ax = gx - Real(i)
    var ay = gy - Real(j)
    for q in range(4):
        var di = q % 2
        var dj = q // 2
        var wq = (ax if di == 1 else 1 - ax) * (ay if dj == 1 else 1 - ay)
        var nxp = (Real(i + di) + ox) * dx - x
        var nyp = (Real(j + dj) + oy) * dx - y
        var k = (j + dj) * w + i + di
        f[k] += wq * (val + cx * nxp + cy * nyp)
        wsum[k] += wq


def _gather_affine(dx: Real, f: List[Real], w: Int, h: Int, x: Real, y: Real, ox: Real, oy: Real) -> Tuple[Real, Real, Real]:
    """(sum w f, sum f dw/dx, sum f dw/dy) for bilinear weights."""
    var gx = min(max(x / dx - ox, Real(0)), Real(w - 1) - 1e-4)
    var gy = min(max(y / dx - oy, Real(0)), Real(h - 1) - 1e-4)
    var i = Int(floor(gx))
    var j = Int(floor(gy))
    var ax = gx - Real(i)
    var ay = gy - Real(j)
    var f00 = f[j * w + i]
    var f10 = f[j * w + i + 1]
    var f01 = f[(j + 1) * w + i]
    var f11 = f[(j + 1) * w + i + 1]
    var val = f00 * (1 - ax) * (1 - ay) + f10 * ax * (1 - ay) + f01 * (1 - ax) * ay + f11 * ax * ay
    var gxv = ((f10 - f00) * (1 - ay) + (f11 - f01) * ay) / dx
    var gyv = ((f01 - f00) * (1 - ax) + (f11 - f10) * ax) / dx
    return (val, gxv, gyv)


def apic_step(mut w: FlipWater2, mut st: ApicState, dt: Real) raises:
    """`FlipWater2.step` with APIC transfers (module note); particles
    without APIC state (added after the last call) start with zero
    gradients."""
    if not (dt > 0):
        raise Error("apic_step: dt must be > 0")
    var nx = w.nx
    var ny = w.ny
    var n = len(w.px)
    st.cux.resize(n, 0)
    st.cuy.resize(n, 0)
    st.cvx.resize(n, 0)
    st.cvy.resize(n, 0)
    w._advect(dt)
    var wu = List[Real](length=(nx + 1) * ny, fill=0)
    var wv = List[Real](length=nx * (ny + 1), fill=0)
    for q in range(len(w.u)):
        w.u[q] = 0
    for q in range(len(w.v)):
        w.v[q] = 0
    for k in range(n):
        _splat_affine(w.u, wu, nx + 1, ny, w.dx, w.px[k], w.py[k], 0, 0.5, w.pu[k], st.cux[k], st.cuy[k])
        _splat_affine(w.v, wv, nx, ny + 1, w.dx, w.px[k], w.py[k], 0.5, 0, w.pv[k], st.cvx[k], st.cvy[k])
    for q in range(len(w.u)):
        if wu[q] > 0:
            w.u[q] /= wu[q]
    for q in range(len(w.v)):
        if wv[q] > 0:
            w.v[q] /= wv[q]
    for q in range(len(w.v)):
        w.v[q] -= w.gravity * dt
    w._walls()
    w._mark()
    w.last = w._project(dt)
    w._walls()
    for k in range(n):
        var gu = _gather_affine(w.dx, w.u, nx + 1, ny, w.px[k], w.py[k], 0, 0.5)
        var gv = _gather_affine(w.dx, w.v, nx, ny + 1, w.px[k], w.py[k], 0.5, 0)
        w.pu[k] = gu[0]
        st.cux[k] = gu[1]
        st.cuy[k] = gu[2]
        w.pv[k] = gv[0]
        st.cvx[k] = gv[1]
        st.cvy[k] = gv[2]
