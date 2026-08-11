"""Exact geometric predicates: robust sign tests for degenerate configurations.

Every hull, clip and simplex routine in this engine ultimately asks a SIGN
question — is this point left of that line, above that plane, inside that
sphere — and answers it by computing a determinant in floating point and
looking at the result. When the true determinant is zero or nearly zero, the
rounding error can exceed it, and the answer is not merely imprecise but
WRONG: three points that are collinear can be reported as a left turn and a
right turn depending on the order they are passed in. A hull builder given
contradictory answers does not produce a slightly wrong hull; it produces one
that is not convex, or loops forever.

The fix is not more precision, it is a decision procedure. Each predicate here
runs in stages, cheapest first, and only escalates when the cheap stage cannot
prove its own answer:

  A. `Real` (float32) arithmetic with a static error bound. Almost every call
     ends here, and it is what the naive code already did.
  B. float64 arithmetic with a bound. Inputs are float32, so widening them is
     exact and this stage alone settles anything that is not near-degenerate.
  C. Exact evaluation. Products and sums are carried in error-free transforms
     (Dekker/Knuth two-product and two-sum) into a non-overlapping expansion,
     whose sign is the sign of its leading non-zero component. This is exact,
     not merely more accurate: the sign returned is the sign of the real
     determinant of the given float32 inputs.

Stage C is deliberately written the slow, obvious way — the Leibniz sum over
permutations — because it is a fallback that runs on a vanishing fraction of
calls, and because a formula that can be read against the textbook is worth
more here than one that is fast. `bench_predicates` prices both regimes.

The exactness claim rests on the inputs being float32: converting one to
float64 is lossless, so stage C is computing with the numbers the caller
actually has, not with a rounded copy of them.
"""

from std.math import sqrt
from .vec import Real, Vec2, Vec3

# Shewchuk's error bounds, in double precision. eps = 2^-53.
comptime _EPS: Float64 = 1.1102230246251565e-16
comptime _O2_BOUND: Float64 = (3.0 + 16.0 * _EPS) * _EPS
comptime _O3_BOUND: Float64 = (7.0 + 56.0 * _EPS) * _EPS
comptime _IC_BOUND: Float64 = (10.0 + 96.0 * _EPS) * _EPS
comptime _IS_BOUND: Float64 = (16.0 + 224.0 * _EPS) * _EPS
comptime _SPLITTER: Float64 = 134217729.0  # 2^27 + 1, for Dekker's split


def _two_sum(a: Float64, b: Float64) -> Tuple[Float64, Float64]:
    """Knuth's error-free sum: a + b == x + y exactly, with |y| <= ulp(x)."""
    var x = a + b
    var bv = x - a
    var y = (a - (x - bv)) + (b - bv)
    return (x, y)


def _split(a: Float64) -> Tuple[Float64, Float64]:
    """Dekker's split into two 26-bit halves, a == hi + lo exactly."""
    var c = _SPLITTER * a
    var abig = c - a
    var hi = c - abig
    return (hi, a - hi)


def _two_product(a: Float64, b: Float64) -> Tuple[Float64, Float64]:
    """Error-free product: a * b == x + y exactly. Written with Dekker's split
    rather than an FMA so it does not depend on the target having one."""
    var x = a * b
    var sa = _split(a)
    var sb = _split(b)
    var err = x - (sa[0] * sb[0])
    err -= sa[1] * sb[0]
    err -= sa[0] * sb[1]
    return (x, (sa[1] * sb[1]) - err)


struct Expansion(Movable, ImplicitlyDeletable):
    """A non-overlapping, increasing-magnitude sequence of doubles whose exact
    sum is the value represented. Shewchuk's representation: every arithmetic
    step below is error free, so the sum never loses a bit."""

    var e: List[Float64]

    def __init__(out self):
        self.e = List[Float64]()

    def grow(mut self, v: Float64):
        """Add one double exactly (Shewchuk's grow_expansion)."""
        var q = v
        for i in range(len(self.e)):
            var s = _two_sum(q, self.e[i])
            q = s[0]
            self.e[i] = s[1]
        self.e.append(q)

    def sign(self) -> Int:
        """The sign of the exact sum: the sign of the leading non-zero
        component, since the components do not overlap."""
        for i in range(len(self.e) - 1, -1, -1):
            if self.e[i] > 0:
                return 1
            if self.e[i] < 0:
                return -1
        return 0


def _add_product(mut acc: Expansion, factors: List[Float64], sgn: Float64):
    """Accumulate `sgn * product(factors)` into `acc`, exactly.

    The running product is itself an expansion: multiplying a k-component
    expansion by one double gives 2k components, all error free, so a product
    of n doubles is exact in 2^(n-1) components."""
    var cur = List[Float64](capacity=32)
    cur.append(sgn)
    for f in range(len(factors)):
        var nxt = List[Float64](capacity=2 * len(cur))
        for i in range(len(cur)):
            var p = _two_product(cur[i], factors[f])
            if p[1] != 0:
                nxt.append(p[1])
            if p[0] != 0:
                nxt.append(p[0])
        cur = nxt^
        if len(cur) == 0:
            return  # an exact zero factor kills the term
    for i in range(len(cur)):
        acc.grow(cur[i])


def _det_exact(n: Int, m: List[Float64], mut acc: Expansion):
    """Accumulate the exact determinant of the row-major n x n matrix `m`.

    Leibniz's sum over permutations. n is 3, 4 or 5 here, so this is 6, 24 or
    120 terms — more than a cofactor expansion would need, and deliberately so:
    this runs only when the filtered stages could not decide, and being able to
    read it straight off the definition is worth more than the factor of two."""
    var perm = List[Int](capacity=n)
    for i in range(n):
        perm.append(i)
    var used = List[Bool](capacity=n)
    for _ in range(n):
        used.append(False)
    _perm_rec(n, 0, m, perm, used, 0, acc)


def _perm_rec(
    n: Int, depth: Int, m: List[Float64], mut perm: List[Int],
    mut used: List[Bool], inversions: Int, mut acc: Expansion,
):
    if depth == n:
        var factors = List[Float64](capacity=n)
        for i in range(n):
            factors.append(m[i * n + perm[i]])
        var sgn = Float64(-1) if (inversions & 1) == 1 else Float64(1)
        _add_product(acc, factors, sgn)
        return
    for c in range(n):
        if used[c]:
            continue
        # inversions contributed by placing column c at this row: how many
        # still-unused columns are smaller than c
        var inv = 0
        for k in range(c):
            if not used[k]:
                inv += 1
        used[c] = True
        perm[depth] = c
        _perm_rec(n, depth + 1, m, perm, used, inversions + inv, acc)
        used[c] = False


# --------------------------------------------------------------------------
# orient2d: is c left of the directed line a -> b?
# --------------------------------------------------------------------------
def orient2d(a: Vec2, b: Vec2, c: Vec2) -> Int:
    """+1 if a, b, c turn counter-clockwise, -1 clockwise, 0 exactly collinear.

    Exactly collinear means exactly: the returned 0 is a proof, not a
    tolerance. That is the property hull and clipping code needs — a tolerance
    can call the same triple collinear from one direction and turning from the
    other, and no downstream code can recover from that."""
    # Widen BEFORE subtracting. Computing the difference in float32 and then
    # widening it rounds, and the double-precision error bound below assumes it
    # did not — a mistake this file's own cyclic-invariance test caught, by
    # reporting orient2d(a, b, c) and orient2d(b, c, a) with opposite signs.
    var detleft = (Float64(a[0]) - Float64(c[0])) * (Float64(b[1]) - Float64(c[1]))
    var detright = (Float64(a[1]) - Float64(c[1])) * (Float64(b[0]) - Float64(c[0]))
    var det = detleft - detright
    var summ = abs(detleft) + abs(detright)
    if abs(det) > _O2_BOUND * summ:
        return 1 if det > 0 else -1
    if summ == 0:
        return 0
    return _orient2d_exact(a, b, c)


def _orient2d_exact(a: Vec2, b: Vec2, c: Vec2) -> Int:
    # (ax-cx)(by-cy) - (ay-cy)(bx-cx), expanded so no subtraction is rounded.
    # The cx*cy terms cancel exactly and are dropped.
    var acc = Expansion()
    var ax = Float64(a[0])
    var ay = Float64(a[1])
    var bx = Float64(b[0])
    var by = Float64(b[1])
    var cx = Float64(c[0])
    var cy = Float64(c[1])
    _pair(acc, ax, by, 1)
    _pair(acc, ax, cy, -1)
    _pair(acc, cx, by, -1)
    _pair(acc, ay, bx, -1)
    _pair(acc, ay, cx, 1)
    _pair(acc, cy, bx, 1)
    return acc.sign()


def _pair(mut acc: Expansion, u: Float64, v: Float64, sgn: Int):
    var p = _two_product(u, v)
    if sgn > 0:
        acc.grow(p[1])
        acc.grow(p[0])
    else:
        acc.grow(-p[1])
        acc.grow(-p[0])


# --------------------------------------------------------------------------
# orient3d: is d below the plane through a, b, c (seen counter-clockwise)?
# --------------------------------------------------------------------------
def orient3d(a: Vec3, b: Vec3, c: Vec3, d: Vec3) -> Int:
    """+1 if d is below the plane abc, -1 above, 0 exactly coplanar.

    Sign convention matches Shewchuk's: positive when a, b, c appear
    counter-clockwise viewed from d's side."""
    var adx = (Float64(a[0]) - Float64(d[0]))
    var ady = (Float64(a[1]) - Float64(d[1]))
    var adz = (Float64(a[2]) - Float64(d[2]))
    var bdx = (Float64(b[0]) - Float64(d[0]))
    var bdy = (Float64(b[1]) - Float64(d[1]))
    var bdz = (Float64(b[2]) - Float64(d[2]))
    var cdx = (Float64(c[0]) - Float64(d[0]))
    var cdy = (Float64(c[1]) - Float64(d[1]))
    var cdz = (Float64(c[2]) - Float64(d[2]))

    var bdxcdy = bdx * cdy
    var cdxbdy = cdx * bdy
    var cdxady = cdx * ady
    var adxcdy = adx * cdy
    var adxbdy = adx * bdy
    var bdxady = bdx * ady

    var det = (
        adz * (bdxcdy - cdxbdy)
        + bdz * (cdxady - adxcdy)
        + cdz * (adxbdy - bdxady)
    )
    var permanent = (
        (abs(bdxcdy) + abs(cdxbdy)) * abs(adz)
        + (abs(cdxady) + abs(adxcdy)) * abs(bdz)
        + (abs(adxbdy) + abs(bdxady)) * abs(cdz)
    )
    if abs(det) > _O3_BOUND * permanent:
        return 1 if det > 0 else -1
    if permanent == 0:
        return 0
    return _orient3d_exact(a, b, c, d)


def _orient3d_exact(a: Vec3, b: Vec3, c: Vec3, d: Vec3) -> Int:
    # The 4x4 homogeneous determinant. Its sign is orient3d's by construction,
    # and unlike the difference form above it contains no subtraction at all,
    # so every entry is an exact float32 and every term is exact.
    var m = List[Float64](capacity=16)
    _row(m, a)
    _row(m, b)
    _row(m, c)
    _row(m, d)
    var acc = Expansion()
    _det_exact(4, m, acc)
    return acc.sign()


def _row(mut m: List[Float64], p: Vec3):
    m.append(Float64(p[0]))
    m.append(Float64(p[1]))
    m.append(Float64(p[2]))
    m.append(1.0)


# --------------------------------------------------------------------------
# incircle / insphere
# --------------------------------------------------------------------------
def incircle(a: Vec2, b: Vec2, c: Vec2, d: Vec2) -> Int:
    """+1 if d is inside the circle through a, b, c, -1 outside, 0 exactly on
    it — PROVIDED a, b, c are counter-clockwise (`orient2d(a, b, c) > 0`). The
    sign follows the orientation, as it must: the same four points with two
    swapped describe the same circle and the opposite determinant."""
    var adx = (Float64(a[0]) - Float64(d[0]))
    var ady = (Float64(a[1]) - Float64(d[1]))
    var bdx = (Float64(b[0]) - Float64(d[0]))
    var bdy = (Float64(b[1]) - Float64(d[1]))
    var cdx = (Float64(c[0]) - Float64(d[0]))
    var cdy = (Float64(c[1]) - Float64(d[1]))

    var bdxcdy = bdx * cdy
    var cdxbdy = cdx * bdy
    var alift = adx * adx + ady * ady
    var cdxady = cdx * ady
    var adxcdy = adx * cdy
    var blift = bdx * bdx + bdy * bdy
    var adxbdy = adx * bdy
    var bdxady = bdx * ady
    var clift = cdx * cdx + cdy * cdy

    var det = (
        alift * (bdxcdy - cdxbdy)
        + blift * (cdxady - adxcdy)
        + clift * (adxbdy - bdxady)
    )
    var permanent = (
        (abs(bdxcdy) + abs(cdxbdy)) * alift
        + (abs(cdxady) + abs(adxcdy)) * blift
        + (abs(adxbdy) + abs(bdxady)) * clift
    )
    if abs(det) > _IC_BOUND * permanent:
        return 1 if det > 0 else -1
    if permanent == 0:
        return 0
    return _incircle_exact(a, b, c, d)


def _incircle_exact(a: Vec2, b: Vec2, c: Vec2, d: Vec2) -> Int:
    # 4x4 determinant with rows (x, y, x^2 + y^2, 1). The lifted column is a
    # SUM, and a determinant is linear in each column, so it splits into two
    # determinants with monomial entries — which keeps every entry an exact
    # float32 product and needs no wider arithmetic than the rest of the file.
    var acc = Expansion()
    for which in range(2):
        var m = List[Float64](capacity=16)
        _ic_row(m, a, which)
        _ic_row(m, b, which)
        _ic_row(m, c, which)
        _ic_row(m, d, which)
        _det_exact(4, m, acc)
    return acc.sign()


def _ic_row(mut m: List[Float64], p: Vec2, which: Int):
    var x = Float64(p[0])
    var y = Float64(p[1])
    m.append(x)
    m.append(y)
    m.append(x * x if which == 0 else y * y)  # exact: float32 squared
    m.append(1.0)


def insphere(a: Vec3, b: Vec3, c: Vec3, d: Vec3, e: Vec3) -> Int:
    """+1 if e is inside the sphere through a, b, c, d, -1 outside, 0 exactly
    on it — PROVIDED the tetrahedron is positively oriented
    (`orient3d(a, b, c, d) > 0`), for the same reason as `incircle`."""
    var aex = (Float64(a[0]) - Float64(e[0]))
    var aey = (Float64(a[1]) - Float64(e[1]))
    var aez = (Float64(a[2]) - Float64(e[2]))
    var bex = (Float64(b[0]) - Float64(e[0]))
    var bey = (Float64(b[1]) - Float64(e[1]))
    var bez = (Float64(b[2]) - Float64(e[2]))
    var cex = (Float64(c[0]) - Float64(e[0]))
    var cey = (Float64(c[1]) - Float64(e[1]))
    var cez = (Float64(c[2]) - Float64(e[2]))
    var dex = (Float64(d[0]) - Float64(e[0]))
    var dey = (Float64(d[1]) - Float64(e[1]))
    var dez = (Float64(d[2]) - Float64(e[2]))

    var ab = aex * bey - bex * aey
    var bc = bex * cey - cex * bey
    var cd = cex * dey - dex * cey
    var da = dex * aey - aex * dey
    var ac = aex * cey - cex * aey
    var bd = bex * dey - dex * bey

    var abc = aez * bc - bez * ac + cez * ab
    var bcd = bez * cd - cez * bd + dez * bc
    var cda = cez * da + dez * ac + aez * cd
    var dab = dez * ab + aez * bd + bez * da

    var alift = aex * aex + aey * aey + aez * aez
    var blift = bex * bex + bey * bey + bez * bez
    var clift = cex * cex + cey * cey + cez * cez
    var dlift = dex * dex + dey * dey + dez * dez

    var det = (dlift * abc - clift * dab) + (blift * cda - alift * bcd)

    var aezplus = abs(aez)
    var bezplus = abs(bez)
    var cezplus = abs(cez)
    var dezplus = abs(dez)
    var abplus = abs(ab)
    var bcplus = abs(bc)
    var cdplus = abs(cd)
    var daplus = abs(da)
    var acplus = abs(ac)
    var bdplus = abs(bd)
    var permanent = (
        ((cdplus * bezplus + bdplus * cezplus + bcplus * dezplus) * alift)
        + ((daplus * cezplus + acplus * dezplus + cdplus * aezplus) * blift)
        + ((abplus * dezplus + bdplus * aezplus + daplus * bezplus) * clift)
        + ((bcplus * aezplus + acplus * bezplus + abplus * cezplus) * dlift)
    )
    if abs(det) > _IS_BOUND * permanent:
        return 1 if det > 0 else -1
    if permanent == 0:
        return 0
    return _insphere_exact(a, b, c, d, e)


def _insphere_exact(a: Vec3, b: Vec3, c: Vec3, d: Vec3, e: Vec3) -> Int:
    # 5x5 determinant with rows (x, y, z, x^2 + y^2 + z^2, 1), split into three
    # determinants by linearity in the lifted column, exactly as `incircle`
    # does. 3 x 120 permutation terms: slow, and only reached when both
    # filtered stages abstain.
    var acc = Expansion()
    for which in range(3):
        var m = List[Float64](capacity=25)
        _is_row(m, a, which)
        _is_row(m, b, which)
        _is_row(m, c, which)
        _is_row(m, d, which)
        _is_row(m, e, which)
        _det_exact(5, m, acc)
    return acc.sign()


def _is_row(mut m: List[Float64], p: Vec3, which: Int):
    var x = Float64(p[0])
    var y = Float64(p[1])
    var z = Float64(p[2])
    m.append(x)
    m.append(y)
    m.append(z)
    if which == 0:
        m.append(x * x)
    elif which == 1:
        m.append(y * y)
    else:
        m.append(z * z)
    m.append(1.0)


# --------------------------------------------------------------------------
# The naive counterparts, kept so the seam can be measured and compared.
# --------------------------------------------------------------------------
def orient2d_naive(a: Vec2, b: Vec2, c: Vec2) -> Int:
    """What the geometry code did before: one float32 determinant, sign taken
    on faith. Kept as the benchmark's and the test's control group."""
    var d = (a[0] - c[0]) * (b[1] - c[1]) - (a[1] - c[1]) * (b[0] - c[0])
    if d > 0:
        return 1
    if d < 0:
        return -1
    return 0


def orient3d_naive(a: Vec3, b: Vec3, c: Vec3, d: Vec3) -> Int:
    var adx = a[0] - d[0]
    var ady = a[1] - d[1]
    var adz = a[2] - d[2]
    var bdx = b[0] - d[0]
    var bdy = b[1] - d[1]
    var bdz = b[2] - d[2]
    var cdx = c[0] - d[0]
    var cdy = c[1] - d[1]
    var cdz = c[2] - d[2]
    var det = (
        adz * (bdx * cdy - cdx * bdy)
        + bdz * (cdx * ady - adx * cdy)
        + cdz * (adx * bdy - bdx * ady)
    )
    if det > 0:
        return 1
    if det < 0:
        return -1
    return 0
