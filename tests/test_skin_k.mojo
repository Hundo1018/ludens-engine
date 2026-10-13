# tier: component
"""K-influence skinning, bind palette, morph targets (ROADMAP 17.65).

  1. Ordinary: K = 2 with weights (w, 1 - w) equals `skin_motor` bit for bit
     on 500 random vertices; K = 1 equals the bone's own motor; K = 4 when
     every bone carries the same rigid motion gives that motion (DLB and
     LBS within 1e-5); one morph target at weight 1 reproduces its shape.
  2. Integration: the palette world x inverse-bind is the identity at the
     bind pose (skinned = rest within 1e-5) and moves vertices with the bone
     after it; morph then skin: a morphed vertex follows its bone; a 4-bone
     shoulder vertex keeps its distance to the bone axis under a 170-degree
     twist with DLB, while LBS shrinks it (the candy-wrapper, measured).
  3. Extreme: all-zero weights give the rest position (DLB and LBS); q and
     -q bones give the same vertex; a NaN bone poisons only its own
     vertices; a bone index out of range, mismatched lengths and K = 0 raise;
     0 vertices; morph weights -1 and 2 extrapolate linearly; a morph index
     out of range raises.
"""

from std.math import sqrt, isnan, sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3, length
from geometry.quat import Quat
from geometry.motor import Motor3
from geometry.mat import Mat4
from geometry.skinning import skin_motor, skin_motor_k, skin_lbs_k, bind_palette, inverse_bind, blend_k
from geometry.morph import MorphSet


def _m(axis: Vec3, ang: Real, t: Vec3) -> Motor3:
    return Motor3.from_quat_translation(Quat.from_axis_angle(axis, ang), t)


def main() raises:
    var s = Suite("skin_k")

    var bones = List[Motor3]()
    for b in range(6):
        bones.append(_m(Vec3(Real(b % 3), 1, Real(b % 2), 0), Real(b) * 0.7 - 1.5, Vec3(Real(b) * 0.3, -Real(b) * 0.1, 0.2, 0)))
    var rest = List[Vec3]()
    var ia = List[Int]()
    var ib = List[Int]()
    var wa = List[Real]()
    var idx2 = List[Int]()
    var w2 = List[Real]()
    for v in range(500):
        rest.append(Vec3(Real(v % 13) * 0.1, Real(v % 7) * 0.2 - 0.5, Real(v % 5) * 0.15, 0))
        var a = v % 6
        var b = (v * 7 + 1) % 6
        var w = Real((v * 37) % 101) / 100
        ia.append(a)
        ib.append(b)
        wa.append(w)
        idx2.append(a)
        idx2.append(b)
        w2.append(w)
        w2.append(1 - w)
    var o1 = List[Vec3](length=500, fill=Vec3(0, 0, 0, 0))
    var o2 = List[Vec3](length=500, fill=Vec3(0, 0, 0, 0))
    skin_motor(bones, rest, ia, ib, wa, o1)
    skin_motor_k(bones, rest, idx2, w2, 2, o2)
    var same = True
    var dmax = Real(0)
    var ndiff = 0
    for v in range(500):
        if o1[v] != o2[v]:
            same = False
            ndiff += 1
            dmax = max(dmax, length(o1[v] - o2[v]))
    print("  K = 2 vs skin_motor: differing vertices", ndiff, " max diff", dmax)
    s.check(same, "K = 2 == skin_motor, bit for bit")

    var one_i = List[Int]()
    var one_w = List[Real]()
    for v in range(500):
        one_i.append(v % 6)
        one_w.append(1)
    skin_motor_k(bones, rest, one_i, one_w, 1, o2)
    var e1 = Real(0)
    for v in range(500):
        e1 = max(e1, length(o2[v] - bones[v % 6].apply_point(rest[v])))
    s.check(e1 < 1e-5, "K = 1: the bone's own motion")

    var same_b = List[Motor3]()
    var same_m = List[Mat4]()
    var rig = _m(Vec3(1, 2, 3, 0), 0.9, Vec3(1, -2, 0.5, 0))
    for _ in range(4):
        same_b.append(rig)
        same_m.append(rig.to_mat4())
    var i4 = List[Int]()
    var w4 = List[Real]()
    for v in range(500):
        for j in range(4):
            i4.append(j)
            w4.append(Real((v + j * 3) % 5 + 1))
    var od = List[Vec3](length=500, fill=Vec3(0, 0, 0, 0))
    var ol = List[Vec3](length=500, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(same_b, rest, i4, w4, 4, od)
    skin_lbs_k(same_m, rest, i4, w4, 4, ol)
    var e4 = Real(0)
    for v in range(500):
        var want = rig.apply_point(rest[v])
        e4 = max(e4, max(length(od[v] - want), length(ol[v] - want)))
    print("  K = 4, one rigid motion on all bones: max |DLB or LBS - motion|", e4)
    s.check(e4 < 1e-5, "K = 4 rigid: DLB and LBS give the common motion")

    # ---- palette ----------------------------------------------------------------------------------
    var bind = List[Motor3]()
    for b in range(3):
        bind.append(_m(Vec3(0, 0, 1, 0), Real(b) * 0.4, Vec3(Real(b), 0, 0, 0)))
    var inv = inverse_bind(bind)
    var pal = bind_palette(bind, inv)
    var ip = List[Int]()
    var wp = List[Real]()
    for v in range(500):
        ip.append(v % 3)
        ip.append((v + 1) % 3)
        wp.append(0.6)
        wp.append(0.4)
    var op = List[Vec3](length=500, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(pal, rest, ip, wp, 2, op)
    var ebind = Real(0)
    for v in range(500):
        ebind = max(ebind, length(op[v] - rest[v]))
    var moved = bind.copy()
    var lift = Motor3.from_translation(Vec3(0, 1, 0, 0))
    for b in range(3):
        moved[b] = lift * moved[b]
    var pal2 = bind_palette(moved, inv)
    skin_motor_k(pal2, rest, ip, wp, 2, op)
    var elift = Real(0)
    for v in range(500):
        elift = max(elift, length(op[v] - (rest[v] + Vec3(0, 1, 0, 0))))
    print("  palette: bind pose max |skinned - rest|", ebind, "  all bones lifted 1 m: max error", elift)
    s.check(ebind < 1e-5 and elift < 1e-5, "palette is the identity at bind pose and follows the bones")

    # ---- morph -------------------------------------------------------------------------------------
    var base: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(1, 0, 0, 0), Vec3(0, 1, 0, 0), Vec3(0, 0, 1, 0)]
    var shape: List[Vec3] = [Vec3(0, 0, 0, 0), Vec3(1.5, 0, 0, 0), Vec3(0, 1, 0, 0), Vec3(0, 0, 0.5, 0)]
    var ms = MorphSet.from_shape(base, shape)
    var w1: List[Real] = [1]
    var mo = List[Vec3](length=4, fill=Vec3(0, 0, 0, 0))
    ms.apply(base, w1, mo)
    var exact = True
    for i in range(4):
        if mo[i] != shape[i]:
            exact = False
    s.check(exact and len(ms.vidx) == 2, "one target at weight 1 == its shape; only moved vertices stored")
    var wneg: List[Real] = [-1]
    var wbig: List[Real] = [2]
    var mn = List[Vec3](length=4, fill=Vec3(0, 0, 0, 0))
    var mb = List[Vec3](length=4, fill=Vec3(0, 0, 0, 0))
    ms.apply(base, wneg, mn)
    ms.apply(base, wbig, mb)
    s.check(mn[1] == Vec3(0.5, 0, 0, 0) and mb[1] == Vec3(2, 0, 0, 0), "weights -1 and 2 extrapolate linearly")
    var mbone: List[Motor3] = [_m(Vec3(0, 1, 0, 0), 1.0, Vec3(0, 0, 3, 0))]
    var mi: List[Int] = [0, 0, 0, 0]
    var mw: List[Real] = [1, 1, 1, 1]
    var sk = List[Vec3](length=4, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(mbone, mo, mi, mw, 1, sk)
    s.check(length(sk[1] - mbone[0].apply_point(Vec3(1.5, 0, 0, 0))) < 1e-5, "morph then skin: the morphed vertex follows its bone")

    # ---- twist: DLB vs LBS ---------------------------------------------------------------------------
    var tw = List[Motor3]()
    var twm = List[Mat4]()
    for j in range(4):
        var ang = Real(2.967) * Real(j) / 3  # 0 .. 170 degrees about x
        var m = _m(Vec3(1, 0, 0, 0), ang, Vec3(0, 0, 0, 0))
        tw.append(m)
        twm.append(m.to_mat4())
    var vtx: List[Vec3] = [Vec3(0.5, 0.2, 0, 0)]
    var ti: List[Int] = [0, 1, 2, 3]
    var tw4: List[Real] = [0.25, 0.25, 0.25, 0.25]
    var td = List[Vec3](length=1, fill=Vec3(0, 0, 0, 0))
    var tl = List[Vec3](length=1, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(tw, vtx, ti, tw4, 4, td)
    skin_lbs_k(twm, vtx, ti, tw4, 4, tl)
    var rd = sqrt(td[0][1] * td[0][1] + td[0][2] * td[0][2])
    var rl = sqrt(tl[0][1] * tl[0][1] + tl[0][2] * tl[0][2])
    print("  4 bones twisted 0..170 deg: radius from the axis (rest 0.2): DLB", rd, " LBS", rl)
    s.check(abs(rd - 0.2) < 1e-4 and rl < 0.8 * 0.2, "DLB keeps the radius, LBS collapses it")

    # ---- extremes --------------------------------------------------------------------------------------
    var zw: List[Real] = [0, 0, 0, 0]
    skin_motor_k(tw, vtx, ti, zw, 4, td)
    skin_lbs_k(twm, vtx, ti, zw, 4, tl)
    s.check(td[0] == vtx[0] and tl[0] == vtx[0], "all-zero weights: the rest position")
    var neg = bones.copy()
    var q = neg[2]
    neg[2] = Motor3(-q.s, -q.b12, -q.b13, -q.b23, -q.b10, -q.b20, -q.b30, -q.pss)
    var on = List[Vec3](length=500, fill=Vec3(0, 0, 0, 0))
    skin_motor_k(neg, rest, idx2, w2, 2, on)
    skin_motor_k(bones, rest, idx2, w2, 2, o2)
    var eq = Real(0)
    for v in range(500):
        eq = max(eq, length(on[v] - o2[v]))
    s.check(eq < 1e-5, "q and -q bones skin the same")
    var nanb = bones.copy()
    nanb[5] = Motor3(Real(0) / Real(0), 0, 0, 0, 0, 0, 0, 0)
    skin_motor_k(nanb, rest, idx2, w2, 2, on)
    var poisoned = 0
    var clean_ok = True
    for v in range(500):
        var uses5 = idx2[2 * v] == 5 or idx2[2 * v + 1] == 5
        if isnan(on[v][0]):
            poisoned += 1
            if not uses5:
                clean_ok = False
    s.check(poisoned > 0 and clean_ok, "a NaN bone poisons only its own vertices")
    var errs = 0
    var bad = idx2.copy()
    bad[7] = 6
    try:
        skin_motor_k(bones, rest, bad, w2, 2, o2)
    except:
        errs += 1
    try:
        skin_motor_k(bones, rest, idx2, wa, 2, o2)
    except:
        errs += 1
    try:
        skin_motor_k(bones, rest, idx2, w2, 0, o2)
    except:
        errs += 1
    try:
        var bi: List[Int] = [9]
        var bd: List[Vec3] = [Vec3(1, 0, 0, 0)]
        _ = ms.add_target(bi, bd)
    except:
        errs += 1
    s.check(errs == 4, "bone index out of range, wrong lengths, K = 0, morph index out of range raise")
    var nv = List[Vec3]()
    var ni = List[Int]()
    var nw = List[Real]()
    var no = List[Vec3]()
    skin_motor_k(bones, nv, ni, nw, 3, no)
    s.check(True, "0 vertices")
    s.finish()
