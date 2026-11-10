"""A curve asset: Catmull-Rom control points (ludens-engine #19, engine 17.36).

The data model is a list of `Vec3` control points through which `geometry.spline.CatmullRom[3]` (centripetal)
passes. This file has what is not a command: the byte format of a curve asset (little-endian, a count then 3 x f32
per point, "LDCV" magic, FNV-1a 64 checksum) and sampling, which calls the engine's own evaluation so a preview is
the engine's curve and not a copy of it."""
from geometry.spline import CatmullRom
from geometry.vec import Real, Vec3

comptime CURVE_MAGIC = 0x5643444C  # "LDCV"


@fieldwise_init
struct CurveStep(Copyable, Movable):
    """One undoable curve edit. op 0 = a point inserted at `idx` (`after`), 1 = point `idx` moved, 2 = point `idx`
    removed (`before`). `key` != 0 lets consecutive moves of the same point merge into one step (a drag)."""
    var op: Int
    var idx: Int
    var before: Vec3
    var after: Vec3
    var key: Int


def _bits_f32(u: UInt32) -> Float32:
    var x = u
    return Pointer(to=x).unsafe_bitcast[Float32]()[]


def _put(mut out: List[UInt8], v: UInt64, n: Int):
    for k in range(n):
        out.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _fnv(data: List[UInt8], n: Int) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(n):
        h = (h ^ UInt64(data[i])) * UInt64(0x100000001B3)
    return h


def curve_to_bytes(points: List[Vec3]) -> List[UInt8]:
    var out = List[UInt8]()
    _put(out, UInt64(CURVE_MAGIC), 4)
    _put(out, UInt64(len(points)), 4)
    for p in points:
        for c in range(3):
            _put(out, UInt64(Float32(p[c]).to_bits()), 4)
    _put(out, _fnv(out, len(out)), 8)
    return out^


def _get(data: List[UInt8], at: Int, n: Int) -> UInt64:
    var v = UInt64(0)
    for k in range(n):
        v |= UInt64(data[at + k]) << UInt64(8 * k)
    return v


def curve_from_bytes(data: List[UInt8]) raises -> List[Vec3]:
    if len(data) < 16:
        raise Error("curve: truncated")
    if Int(_get(data, 0, 4)) != CURVE_MAGIC:
        raise Error("curve: not a curve asset")
    var n = Int(_get(data, 4, 4))
    if n < 0 or len(data) != 8 + 12 * n + 8:
        raise Error("curve: length does not match the point count")
    if _fnv(data, len(data) - 8) != _get(data, len(data) - 8, 8):
        raise Error("curve: checksum mismatch")
    var out = List[Vec3]()
    for i in range(n):
        var comps = List[Real]()
        for c in range(3):
            comps.append(Real(_bits_f32(UInt32(_get(data, 8 + 12 * i + 4 * c, 4)))))
        out.append(Vec3(comps[0], comps[1], comps[2], 0))
    return out^


def sample_curve(points: List[Vec3], n: Int) raises -> List[Vec3]:
    """`n` points evenly spaced in the spline parameter from the first control point to the last. At least two
    control points and n >= 2."""
    if len(points) < 2:
        raise Error("curve: needs at least 2 control points")
    if n < 2:
        raise Error("curve: needs at least 2 samples")
    var c = CatmullRom[3](points.copy())
    var out = List[Vec3]()
    var tmax = c.domain_max()
    for i in range(n):
        out.append(c.eval(tmax * Real(i) / Real(n - 1)))
    return out^
