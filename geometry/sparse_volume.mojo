"""Sparse volumes, VDB-style, and their byte format (ROADMAP 17.63).

`SparseVolume` stores a scalar field on an integer voxel lattice as 8^3
leaves found by hash (`Dict` keyed by the leaf origin), each with an active
mask; inactive voxels read the `background` value. That is the leaf level
of OpenVDB (Museth 2013) without its internal tree levels: for a field that
is mostly background (a narrow band, smoke, a fluid in a big box) memory
and bytes follow the active voxels, not the box.

`encode()` -> bytes ("LDSV", version 1, background, leaf count, then per
leaf: origin (3 x i32), 512-bit mask, active values as f64 bits, then an
FNV-1a 64 checksum of everything before it); `decode_volume` validates
magic, version, sizes and checksum and raises instead of reading past the
end. Values are stored as f64, so a round trip is exact in both the f32
and the f64 build. `from_dense` / `to_dense` convert from / to a dense
nx x ny x nz array (values equal to the background stay inactive).

This is the repo's own interchange container; the OpenVDB / NanoVDB file
formats themselves are not written (no tool here to check them against).
"""

from .vec import Real

comptime LEAF = 8
comptime _LEAF3 = 512
comptime _VERSION = 1


def _f64_bits(v: Float64) -> UInt64:
    var x = v
    return Pointer(to=x).unsafe_bitcast[UInt64]()[]


def _bits_f64(u: UInt64) -> Float64:
    var x = u
    return Pointer(to=x).unsafe_bitcast[Float64]()[]


def _put(mut b: List[UInt8], v: UInt64, n: Int):
    for k in range(n):
        b.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _get(d: List[UInt8], at: Int, n: Int) -> UInt64:
    var v = UInt64(0)
    for k in range(n):
        v |= UInt64(d[at + k]) << UInt64(8 * k)
    return v


def _fnv(b: List[UInt8], n: Int) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for i in range(n):
        h ^= UInt64(b[i])
        h *= UInt64(0x100000001B3)
    return h


def _floor_div(a: Int, b: Int) -> Int:
    var q = a // b
    return q


def _key(lx: Int, ly: Int, lz: Int) -> Int:
    """Leaf coordinates (voxel // 8) packed into one Int (21 bits each)."""
    var m = (1 << 21) - 1
    return ((lx & m) << 42) | ((ly & m) << 21) | (lz & m)


struct _Leaf(Copyable, Movable):
    var ox: Int  # origin voxel (a multiple of 8)
    var oy: Int
    var oz: Int
    var mask: List[Bool]
    var val: List[Real]

    def __init__(out self, ox: Int, oy: Int, oz: Int, background: Real):
        self.ox = ox
        self.oy = oy
        self.oz = oz
        self.mask = List[Bool](length=_LEAF3, fill=False)
        self.val = List[Real](length=_LEAF3, fill=background)


struct SparseVolume(Movable):
    var background: Real
    var leaves: List[_Leaf]
    var index: Dict[Int, Int]

    def __init__(out self, background: Real = 0):
        self.background = background
        self.leaves = List[_Leaf]()
        self.index = Dict[Int, Int]()

    def _leaf_of(self, x: Int, y: Int, z: Int) -> Int:
        var k = _key(_floor_div(x, LEAF), _floor_div(y, LEAF), _floor_div(z, LEAF))
        return self.index.get(k, -1)

    def get(self, x: Int, y: Int, z: Int) -> Real:
        var li = self._leaf_of(x, y, z)
        if li < 0:
            return self.background
        ref lf = self.leaves[li]
        var o = ((z - lf.oz) * LEAF + (y - lf.oy)) * LEAF + (x - lf.ox)
        return lf.val[o] if lf.mask[o] else self.background

    def set(mut self, x: Int, y: Int, z: Int, v: Real):
        """Make voxel (x, y, z) active with value v (leaves are created on
        demand)."""
        var lx = _floor_div(x, LEAF)
        var ly = _floor_div(y, LEAF)
        var lz = _floor_div(z, LEAF)
        var k = _key(lx, ly, lz)
        var li = self.index.get(k, -1)
        if li < 0:
            li = len(self.leaves)
            self.leaves.append(_Leaf(lx * LEAF, ly * LEAF, lz * LEAF, self.background))
            self.index[k] = li
        ref lf = self.leaves[li]
        var o = ((z - lf.oz) * LEAF + (y - lf.oy)) * LEAF + (x - lf.ox)
        lf.mask[o] = True
        lf.val[o] = v

    def active_voxels(self) -> Int:
        var n = 0
        for ref lf in self.leaves:
            for m in lf.mask:
                if m:
                    n += 1
        return n

    def leaf_count(self) -> Int:
        return len(self.leaves)

    def encode(self) -> List[UInt8]:
        var b = List[UInt8]()
        for ch in [0x4C, 0x44, 0x53, 0x56]:  # "LDSV"
            b.append(UInt8(ch))
        _put(b, UInt64(_VERSION), 4)
        _put(b, _f64_bits(Float64(self.background)), 8)
        _put(b, UInt64(len(self.leaves)), 8)
        for ref lf in self.leaves:
            _put(b, UInt64(lf.ox & 0xFFFFFFFF), 4)
            _put(b, UInt64(lf.oy & 0xFFFFFFFF), 4)
            _put(b, UInt64(lf.oz & 0xFFFFFFFF), 4)
            for word in range(_LEAF3 // 64):
                var w = UInt64(0)
                for bit in range(64):
                    if lf.mask[word * 64 + bit]:
                        w |= UInt64(1) << UInt64(bit)
                _put(b, w, 8)
            for o in range(_LEAF3):
                if lf.mask[o]:
                    _put(b, _f64_bits(Float64(lf.val[o])), 8)
        _put(b, _fnv(b, len(b)), 8)
        return b^


def _i32(u: UInt64) -> Int:
    var v = Int(u & 0xFFFFFFFF)
    return v - (1 << 32) if v >= (1 << 31) else v


def decode_volume(d: List[UInt8]) raises -> SparseVolume:
    """Inverse of `SparseVolume.encode` (module note)."""
    var n = len(d)
    if n < 32 or d[0] != 0x4C or d[1] != 0x44 or d[2] != 0x53 or d[3] != 0x56:
        raise Error("decode_volume: not a sparse volume (magic)")
    if _get(d, n - 8, 8) != _fnv(d, n - 8):
        raise Error("decode_volume: checksum mismatch")
    var ver = Int(_get(d, 4, 4))
    if ver != _VERSION:
        raise Error("decode_volume: unknown version")
    var vol = SparseVolume(Real(_bits_f64(_get(d, 8, 8))))
    var leaves = Int(_get(d, 16, 8))
    var at = 24
    var end = n - 8
    for _ in range(leaves):
        if at + 12 + 64 > end:
            raise Error("decode_volume: truncated leaf header")
        var ox = _i32(_get(d, at, 4))
        var oy = _i32(_get(d, at + 4, 4))
        var oz = _i32(_get(d, at + 8, 4))
        at += 12
        var mask = List[Bool](length=_LEAF3, fill=False)
        for word in range(_LEAF3 // 64):
            var w = _get(d, at, 8)
            at += 8
            for bit in range(64):
                mask[word * 64 + bit] = ((w >> UInt64(bit)) & 1) == 1
        for o in range(_LEAF3):
            if mask[o]:
                if at + 8 > end:
                    raise Error("decode_volume: truncated values")
                var v = Real(_bits_f64(_get(d, at, 8)))
                at += 8
                var z = o // (LEAF * LEAF)
                var y = (o // LEAF) % LEAF
                var x = o % LEAF
                vol.set(ox + x, oy + y, oz + z, v)
    if at != end:
        raise Error("decode_volume: trailing bytes")
    return vol^


def from_dense(values: List[Real], nx: Int, ny: Int, nz: Int, background: Real) raises -> SparseVolume:
    """Voxels whose value differs from `background` become active
    (values[(k * ny + j) * nx + i])."""
    if len(values) != nx * ny * nz:
        raise Error("from_dense: values must hold nx * ny * nz entries")
    var vol = SparseVolume(background)
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                var v = values[(k * ny + j) * nx + i]
                if v != background:
                    vol.set(i, j, k, v)
    return vol^


def to_dense(vol: SparseVolume, nx: Int, ny: Int, nz: Int) -> List[Real]:
    var out = List[Real](length=nx * ny * nz, fill=vol.background)
    for k in range(nz):
        for j in range(ny):
            for i in range(nx):
                out[(k * ny + j) * nx + i] = vol.get(i, j, k)
    return out^
