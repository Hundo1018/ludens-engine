"""DCGA spike: quartic surfaces (the torus) as a LINEAR incidence test.

Why this exists. Conformal GA `Cl(4,1)` represents points, spheres, planes,
lines, circles and point pairs — every one a quadric or lower. A torus is a
QUARTIC, so it is not a CGA round at all, and "torus-torus intersection via
CGA" is not an unimplemented feature but a category error. Double CGA
(`Cl(8,2)`) is the algebra that does cover it, by tensoring two conformal
copies so that products of the two points supply degree-4 monomials.

Why it is written like this rather than as `Multivector[8, 2, 0]`. That
instantiation is out of reach on this toolchain, and measurably so rather than
as a guess: the generic multivector unrolls the geometric product fully at
compile time, so cost grows with the SQUARE of the blade count. Measured wall
times for one product — 32 blades 4 s, 64 2 s, 128 8 s, 256 30 s, 512 exceeds a
6 GB address-space cap, and `Cl(8,2)`'s 1024 blades (about a million term
products) was killed by the OOM killer outright. So the dense path is
structurally unavailable, not slow.

What is implemented instead is what DCGA implementations actually compute. The
tensor product of two conformal points spans the 15 distinct monomials

    s², s·x, s·y, s·z, x², y², z², xy, yz, zx, s, x, y, z, 1   (s = x²+y²+z²)

and every Darboux cyclide — the family containing planes, spheres, ellipsoids,
cyclides and the torus — is a fixed coefficient vector against that basis. So
the incidence test `TD · Omega = 0` collapses to a 15-term dot product, and the
UNIFORMITY claim becomes concrete and checkable: one code path, one inner
product, answers plane, sphere and torus alike, with the surface type living
entirely in the coefficients.

Limitation kept explicit: the entities here are axis-aligned (torus about z).
A general pose needs the surface coefficients transformed, which in full DCGA
is a versor sandwich and here would be a change of monomial basis.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot

comptime DCGA_DIM = 15

# monomial slots
comptime _S2 = 0
comptime _SX = 1
comptime _SY = 2
comptime _SZ = 3
comptime _XX = 4
comptime _YY = 5
comptime _ZZ = 6
comptime _XY = 7
comptime _YZ = 8
comptime _ZX = 9
comptime _S = 10
comptime _X = 11
comptime _Y = 12
comptime _Z = 13
comptime _ONE = 14


@fieldwise_init
struct DcgaEntity(Copyable, ImplicitlyCopyable, Movable):
    """A Darboux-cyclide surface as coefficients over the monomial basis."""

    var c: InlineArray[Real, DCGA_DIM]

    @staticmethod
    def zero() -> Self:
        return Self(InlineArray[Real, DCGA_DIM](fill=0))


def dcga_point(p: Vec3) -> InlineArray[Real, DCGA_DIM]:
    """Monomial extraction from a euclidean point — the value-extraction
    components of the tensored conformal point, written directly."""
    var x = p[0]
    var y = p[1]
    var z = p[2]
    var s = x * x + y * y + z * z
    var v = InlineArray[Real, DCGA_DIM](fill=0)
    v[_S2] = s * s
    v[_SX] = s * x
    v[_SY] = s * y
    v[_SZ] = s * z
    v[_XX] = x * x
    v[_YY] = y * y
    v[_ZZ] = z * z
    v[_XY] = x * y
    v[_YZ] = y * z
    v[_ZX] = z * x
    v[_S] = s
    v[_X] = x
    v[_Y] = y
    v[_Z] = z
    v[_ONE] = 1
    return v


def dcga_incidence(pt: InlineArray[Real, DCGA_DIM], e: DcgaEntity) -> Real:
    """`TD · Omega`: zero on the surface, signed off it. ONE expression for
    every surface in the family — that is the whole DCGA claim."""
    var acc = Real(0)
    comptime for i in range(DCGA_DIM):
        acc += pt[i] * e.c[i]
    return acc


def dcga_plane(normal: Vec3, d: Real) -> DcgaEntity:
    """`n·p - d`."""
    var e = DcgaEntity.zero()
    e.c[_X] = normal[0]
    e.c[_Y] = normal[1]
    e.c[_Z] = normal[2]
    e.c[_ONE] = -d
    return e^


def dcga_sphere(center: Vec3, radius: Real) -> DcgaEntity:
    """`|p-c|² - r²` = s - 2c·p + |c|² - r²."""
    var e = DcgaEntity.zero()
    e.c[_S] = 1
    e.c[_X] = -2 * center[0]
    e.c[_Y] = -2 * center[1]
    e.c[_Z] = -2 * center[2]
    e.c[_ONE] = dot(center, center) - radius * radius
    return e^


def dcga_torus(major: Real, minor: Real) -> DcgaEntity:
    """Torus about the z axis: `(s + R² - r²)² - 4R²(x² + y²)`.

    This is the entity CGA cannot hold. Expanding gives
    `s² + 2k·s - 4R²x² - 4R²y² + k²` with `k = R² - r²`, so it is a fixed
    coefficient vector over the same monomial basis a plane and a sphere use —
    which is exactly what "the doubled algebra linearises quartics" means in
    practice."""
    var k = major * major - minor * minor
    var e = DcgaEntity.zero()
    e.c[_S2] = 1
    e.c[_S] = 2 * k
    e.c[_XX] = -4 * major * major
    e.c[_YY] = -4 * major * major
    e.c[_ONE] = k * k
    return e^


def torus_analytic(major: Real, minor: Real, p: Vec3) -> Real:
    """Hand-written torus implicit, the control for the DCGA path."""
    var q = sqrt(p[0] * p[0] + p[1] * p[1]) - major
    return q * q + p[2] * p[2] - minor * minor
