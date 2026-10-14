# tier: integration
"""Cloth material models (ROADMAP 17.56): dihedral bending, strain limit,
anisotropic stretch.

  1. Ordinary: a flat sheet scaled 10 % in its own plane (zero gravity,
     stretch made free, bending stiff): the cross-edge bending constraints
     pull it back (they are distances), the dihedral ones do not move it
     at all (the angles are unchanged) -- bending independent of stretch.
     A clamped strip sags less with stiff dihedral bending than with soft.
  2. Integration: a soft sheet hanging from two corners stretches its
     edges by over 20 %; with `set_max_stretch(1.1)` no edge exceeds 10 %.
     A vertical sheet hung from its top row stretches downwards far less
     when the vertical axis is the stiff one of `set_anisotropy`.
  3. Extreme: an unknown bend model, a stretch ratio below 1 and a zero
     anisotropy axis raise; the default model is the cross-edge one.
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real, Vec3, dot
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6
from physics.cloth import MeshCloth, grid_mesh, BEND_CROSS_EDGE, BEND_DIHEDRAL

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)
comptime ZERO = Vec3(0, 0, 0, 0)


def _edge_ratio_max(c: MeshCloth) -> Real:
    var worst = Real(0)
    for e in range(len(c.ea)):
        var d = c.x[c.eb[e]] - c.x[c.ea[e]]
        worst = max(worst, sqrt(dot(d, d)) / c.rest[e])
    return worst


def _scaled_drift(model: Int) raises -> Real:
    var m = grid_mesh(8, 8, 1, 1, Vec3(-0.5, 0, -0.5, 0))
    var c = MeshCloth(m[0], m[1], 0.2, 1e6, 0)
    c.set_bend_model(model)
    for i in range(len(c.x)):
        c.x[i] = Vec3(c.x[i][0] * 1.1, 0, c.x[i][2] * 1.1, 0)
        c.prev[i] = c.x[i]
    var start = c.x.copy()
    c.advance(DT, ZERO)
    var d = Real(0)
    for i in range(len(c.x)):
        var r = c.x[i] - start[i]
        d = max(d, sqrt(dot(r, r)))
    return d


def _strip_sag(bend: Real) raises -> Real:
    var m = grid_mesh(6, 1, 0.3, 0.05, Vec3(0, 1, 0, 0))
    var st = MeshCloth(m[0], m[1], 0.2, 0, bend)
    st.set_bend_model(BEND_DIHEDRAL)
    for i in [0, 1, 7, 8]:
        st.pin(i)
    var sag = Real(0)
    for k in range(240):
        st.advance(DT, G)
        if k >= 120:
            sag += 1 - st.x[6][1]
    return sag / 120  # mean over the second 2 s (the soft strip swings)


def _hang(cap: Real) raises -> Real:
    var m = grid_mesh(10, 10, 1, 1, Vec3(-0.5, 1, -0.5, 0))
    var c = MeshCloth(m[0], m[1], 0.2, 1.0, 1e-3)
    c.pin(0)
    c.pin(10)
    if cap > 0:
        c.set_max_stretch(cap)
    for _ in range(120):
        c.advance(DT, G)
    return _edge_ratio_max(c)


def _vertical(axis_stiff_vertical: Bool) raises -> Real:
    """Mean length ratio of the vertical edges of a hanging sheet."""
    var m = grid_mesh(8, 8, 1, 1, Vec3(-0.5, 0, 0, 0))
    var v = m[0].copy()
    for i in range(len(v) // 3):
        var z = v[3 * i + 2]
        v[3 * i + 1] = 1 - z  # the sheet's z becomes height
        v[3 * i + 2] = 0
    var c = MeshCloth(v, m[1], 0.2, 0, 1e-3)
    c.set_bend_model(BEND_DIHEDRAL)  # cross-edge bending would also hold the stretch
    for i in range(9):
        c.pin(i)  # top row
    if axis_stiff_vertical:
        c.set_anisotropy(Vec3(0, 1, 0, 0), 0, 1.0, 1.0)
    else:
        c.set_anisotropy(Vec3(0, 1, 0, 0), 1.0, 0, 1.0)
    for _ in range(120):
        c.advance(DT, G)
    var sum = Real(0)
    var n = 0
    for e in range(len(c.ea)):
        var r = c.x[c.eb[e]] - c.x[c.ea[e]]
        var r0 = c.rest[e]
        var a = c.ea[e]
        var b = c.eb[e]
        if a % 9 == b % 9:  # same column: a vertical edge
            sum += sqrt(dot(r, r)) / r0
            n += 1
    return sum / Real(n)


def main() raises:
    var s = Suite("cloth_models")
    var cross_d = _scaled_drift(BEND_CROSS_EDGE)
    var dihed_d = _scaled_drift(BEND_DIHEDRAL)
    print("  flat sheet scaled 10 % in plane, one step: largest move  cross-edge bending", cross_d, " dihedral", dihed_d)
    s.check(cross_d > 1e-3 and dihed_d < 1e-6, "dihedral bending ignores in-plane stretch; cross-edge bending pulls it back")
    var soft = _strip_sag(100)
    var stiff = _strip_sag(1e-6)
    print("  clamped strip, dihedral bending: sag soft", soft, " stiff", stiff)
    s.check(stiff < soft * 0.7, "stiff dihedral bending sags less than soft")

    var free = _hang(0)
    var capped = _hang(1.1)
    print("  soft sheet from two corners, 2 s: largest edge ratio  free", free, " capped at 1.1", capped)
    s.check(free > 1.2 and capped <= 1.1 + 1e-3, "strain limit: edges stay within 10 % (free: over 20 %)")

    var sv = _vertical(True)
    var sh = _vertical(False)
    print("  vertical sheet hung 2 s: mean vertical edge ratio  stiff vertical axis", sv, " stiff horizontal axis", sh)
    s.check(sv < 1.01 and sh > sv + 0.02, "anisotropy: the stiff axis carries the weight")

    var raised = 0
    var m = grid_mesh(2, 2, 1, 1, ZERO)
    var c = MeshCloth(m[0], m[1], 0.2)
    try:
        c.set_bend_model(7)
    except:
        raised += 1
    try:
        c.set_max_stretch(0.5)
    except:
        raised += 1
    try:
        c.set_anisotropy(ZERO, 0, 1, 1)
    except:
        raised += 1
    s.check(raised == 3 and c.bend_model == BEND_CROSS_EDGE, "bad model, ratio < 1, zero axis raise; default is cross-edge")
    s.finish()
