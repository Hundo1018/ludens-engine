"""OpenVDB `.vdb` files from a `SparseVolume` (ROADMAP 17.63).

`vdb_bytes(vol, name, voxel_size)` writes one FloatGrid in the OpenVDB file
format (file version 224, the layout of `openvdb::io::File::write` with no
compression, Museth 2013): the header (magic, versions, grid offsets on,
UUID), no file metadata, one grid descriptor ("Tree_float_5_4_3") with its
stream offsets, the grid metadata (only "name", which the reader uses as
the grid's name), a uniform-scale transform (voxel size in f64), the
topology and then the leaf buffers.

The tree is the standard 5-4-3 configuration: `SparseVolume`'s 8^3 leaves
grouped under 16^3-leaf internal nodes (128^3 voxels) and those under
32^3-child internal nodes (4096^3 voxels) hanging off the root, all as
children (no tiles). Per node, as OpenVDB writes it: child mask and value
mask (64-bit words), then one metadata byte and the values; leaves write
their value mask in the topology and mask + metadata byte + values in the
buffers. Two value layouts, both read by OpenVDB: `active_mask=True`
(the default; compression flag COMPRESS_ACTIVE_MASK) writes metadata 0
("inactive values are the background") and only the active values, so an
internal node costs its two masks and one byte; `active_mask=False`
writes metadata 6 ("all values") and every value raw. Inside a node the voxel
/ child index is x-major (x << 2 log2dim | y << log2dim | z), where
`SparseVolume` stores leaves z-major: the order is converted. Values are
written as f32.

Checked against the real reader: `pixi run vdb-check` opens the file with
OpenVDB's Python module (`scripts/vdb_check.py`, conda-forge `openvdb`)
and compares every active voxel (`test_vdb_file` writes the files).
"""

from .vec import Real
from .sparse_volume import SparseVolume, LEAF


def _u32(mut b: List[UInt8], v: Int):
    for k in range(4):
        b.append(UInt8((v >> (8 * k)) & 0xFF))


def _u64(mut b: List[UInt8], v: Int):
    for k in range(8):
        b.append(UInt8((v >> (8 * k)) & 0xFF))


def _set_u64(mut b: List[UInt8], at: Int, v: Int):
    for k in range(8):
        b[at + k] = UInt8((v >> (8 * k)) & 0xFF)


def _f32(mut b: List[UInt8], v: Real):
    var x = Float32(v)
    var u = Int(Pointer(to=x).unsafe_bitcast[UInt32]()[])
    _u32(b, u)


def _f64(mut b: List[UInt8], v: Float64):
    var x = v
    var u = Pointer(to=x).unsafe_bitcast[UInt64]()[]
    for k in range(8):
        b.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _string(mut b: List[UInt8], s: String):
    var bytes = s.as_bytes()
    _u32(b, len(bytes))
    for c in bytes:
        b.append(c)


def _mask(mut b: List[UInt8], bits: List[Bool]):
    """A node mask as OpenVDB saves it: 64-bit words, bit n in word n / 64."""
    for w in range(len(bits) // 64):
        var word = UInt64(0)
        for k in range(64):
            if bits[w * 64 + k]:
                word |= UInt64(1) << UInt64(k)
        for k in range(8):
            b.append(UInt8((word >> UInt64(8 * k)) & 0xFF))


def _floor(a: Int, m: Int) -> Int:
    """a rounded down to a multiple of m (m a power of two)."""
    return a & ~(m - 1)


struct _Inner1(Copyable, Movable):
    var ox: Int
    var oy: Int
    var oz: Int
    var leaves: List[Int]  # SparseVolume leaf index per child slot (-1 = none), 4096

    def __init__(out self, ox: Int, oy: Int, oz: Int):
        self.ox = ox
        self.oy = oy
        self.oz = oz
        self.leaves = List[Int](length=4096, fill=-1)


struct _Inner2(Copyable, Movable):
    var ox: Int
    var oy: Int
    var oz: Int
    var kids: List[Int]  # index into the _Inner1 list per child slot (-1), 32768

    def __init__(out self, ox: Int, oy: Int, oz: Int):
        self.ox = ox
        self.oy = oy
        self.oz = oz
        self.kids = List[Int](length=32768, fill=-1)


def _lex_less(ax: Int, ay: Int, az: Int, bx: Int, by: Int, bz: Int) -> Bool:
    if ax != bx:
        return ax < bx
    if ay != by:
        return ay < by
    return az < bz


def vdb_bytes(
    vol: SparseVolume, name: String, voxel_size: Float64, active_mask: Bool = True
) raises -> List[UInt8]:
    if not (voxel_size > 0):
        raise Error("vdb_bytes: voxel_size must be > 0")
    # group leaves: 128^3 internal nodes under 4096^3 internal nodes
    var tops = List[_Inner2]()
    var mids = List[_Inner1]()
    var top_of = Dict[String, Int]()
    var mid_of = Dict[String, Int]()
    for li in range(len(vol.leaves)):
        ref lf = vol.leaves[li]
        var tx = _floor(lf.ox, 4096)
        var ty = _floor(lf.oy, 4096)
        var tz = _floor(lf.oz, 4096)
        var tk = String(tx) + "," + String(ty) + "," + String(tz)
        var ti = top_of.get(tk, -1)
        if ti < 0:
            ti = len(tops)
            tops.append(_Inner2(tx, ty, tz))
            top_of[tk] = ti
        var mx = _floor(lf.ox, 128)
        var my = _floor(lf.oy, 128)
        var mz = _floor(lf.oz, 128)
        var mk = String(mx) + "," + String(my) + "," + String(mz)
        var mi = mid_of.get(mk, -1)
        if mi < 0:
            mi = len(mids)
            mids.append(_Inner1(mx, my, mz))
            mid_of[mk] = mi
            var slot = (((mx - tx) >> 7) << 10) | (((my - ty) >> 7) << 5) | ((mz - tz) >> 7)
            tops[ti].kids[slot] = mi
        var lslot = (((lf.ox - mx) >> 3) << 8) | (((lf.oy - my) >> 3) << 4) | ((lf.oz - mz) >> 3)
        mids[mi].leaves[lslot] = li
    # the root's map is ordered by origin (x, then y, then z)
    var order = List[Int]()
    for i in range(len(tops)):
        order.append(i)
    for i in range(1, len(order)):
        var j = i
        while j > 0 and _lex_less(tops[order[j]].ox, tops[order[j]].oy, tops[order[j]].oz, tops[order[j - 1]].ox, tops[order[j - 1]].oy, tops[order[j - 1]].oz):
            var tmp = order[j]
            order[j] = order[j - 1]
            order[j - 1] = tmp
            j -= 1

    var b = List[UInt8]()
    # header
    _u64(b, 0x56444220)
    _u32(b, 224)
    _u32(b, 10)
    _u32(b, 0)
    b.append(1)  # grid offsets follow
    var uuid = "1d4b5e3a-7c21-4c55-9a6e-0f3b2d5e8a17"
    for c in uuid.as_bytes():
        b.append(c)
    _u32(b, 0)  # file metadata: none
    _u32(b, 1)  # one grid
    # grid descriptor
    _string(b, name)
    _string(b, "Tree_float_5_4_3")
    _string(b, "")  # instance parent
    var pos_at = len(b)
    _u64(b, 0)
    _u64(b, 0)
    _u64(b, 0)
    var grid_pos = len(b)
    _u32(b, 2 if active_mask else 0)  # compression: COMPRESS_ACTIVE_MASK or none
    # grid metadata: the name (the reader takes the grid's name from here)
    _u32(b, 1)
    _string(b, "name")
    _string(b, "string")
    _string(b, name)
    _string(b, "UniformScaleMap")
    var s = voxel_size
    for _ in range(3):
        _f64(b, s)  # scale values
    for _ in range(3):
        _f64(b, s)  # voxel size
    for _ in range(3):
        _f64(b, 1 / s)  # inverse scale
    for _ in range(3):
        _f64(b, 1 / (s * s))  # inverse scale squared
    for _ in range(3):
        _f64(b, 1 / (2 * s))  # inverse twice scale
    # topology
    _u32(b, 1)  # buffer count
    _f32(b, vol.background)
    _u32(b, 0)  # tiles
    _u32(b, len(tops))  # children
    for t in order:
        ref top = tops[t]
        _u32(b, top.ox)
        _u32(b, top.oy)
        _u32(b, top.oz)
        var cm = List[Bool](length=32768, fill=False)
        for k in range(32768):
            cm[k] = top.kids[k] >= 0
        _mask(b, cm)
        _mask(b, List[Bool](length=32768, fill=False))
        _inactive_values(b, 32768, vol.background, active_mask)
        for k in range(32768):
            if top.kids[k] < 0:
                continue
            ref mid = mids[top.kids[k]]
            var lm = List[Bool](length=4096, fill=False)
            for q in range(4096):
                lm[q] = mid.leaves[q] >= 0
            _mask(b, lm)
            _mask(b, List[Bool](length=4096, fill=False))
            _inactive_values(b, 4096, vol.background, active_mask)
            for q in range(4096):
                if mid.leaves[q] >= 0:
                    _mask(b, _leaf_mask(vol, mid.leaves[q]))
    var block_pos = len(b)
    # buffers, leaves in the same order
    for t in order:
        ref top = tops[t]
        for k in range(32768):
            if top.kids[k] < 0:
                continue
            ref mid = mids[top.kids[k]]
            for q in range(4096):
                var li = mid.leaves[q]
                if li < 0:
                    continue
                _mask(b, _leaf_mask(vol, li))
                b.append(UInt8(0) if active_mask else UInt8(6))
                ref lf = vol.leaves[li]
                for o in range(512):
                    # x-major offset o -> SparseVolume's z-major one
                    var x = o >> 6
                    var y = (o >> 3) & 7
                    var z = o & 7
                    var src = (z * LEAF + y) * LEAF + x
                    if lf.mask[src]:
                        _f32(b, lf.val[src])
                    elif not active_mask:
                        _f32(b, vol.background)
    var end_pos = len(b)
    _set_u64(b, pos_at, grid_pos)
    _set_u64(b, pos_at + 8, block_pos)
    _set_u64(b, pos_at + 16, end_pos)
    return b^


def _inactive_values(mut b: List[UInt8], n: Int, background: Real, active_mask: Bool):
    """An internal node's value array (no active tiles: every value is the
    background). With active-mask compression: metadata byte 0 ("inactive
    values are the background") and the active values only, here none."""
    if active_mask:
        b.append(0)
        return
    b.append(6)
    for _ in range(n):
        _f32(b, background)


def _leaf_mask(vol: SparseVolume, li: Int) -> List[Bool]:
    ref lf = vol.leaves[li]
    var m = List[Bool](length=512, fill=False)
    for o in range(512):
        var x = o >> 6
        var y = (o >> 3) & 7
        var z = o & 7
        m[o] = lf.mask[(z * LEAF + y) * LEAF + x]
    return m^
