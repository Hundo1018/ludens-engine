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

`vdb_grid(bytes)` reads the first grid back into a `SparseVolume` (both
value layouts, every metadata byte kind); it raises on what it cannot hold
or does not decode: half floats, blosc codecs other than LZ4, other grid
types or transforms, root-level tiles, mismatched offsets, truncation.

Checked against the real reader: `pixi run vdb-check` opens the file with
OpenVDB's Python module (`scripts/vdb_check.py`, conda-forge `openvdb`)
and compares every active voxel (`test_vdb_file` writes the files).
"""

from geometry.inflate import zlib_inflate
from geometry.blosc import blosc_decode
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


struct VdbGrid(Movable):
    """One float grid read back by `vdb_grid`: its name, voxel size and the
    active voxels as a `SparseVolume`."""

    var name: String
    var voxel_size: Float64
    var volume: SparseVolume

    def __init__(out self, var name: String, voxel_size: Float64, var volume: SparseVolume):
        self.name = name^
        self.voxel_size = voxel_size
        self.volume = volume^


def _need(d: List[UInt8], at: Int, n: Int) raises:
    if n < 0 or at + n > len(d):
        raise Error("vdb_grid: truncated file")


def _rd_u32(d: List[UInt8], mut at: Int) raises -> Int:
    _need(d, at, 4)
    var v = 0
    for k in range(4):
        v |= Int(d[at + k]) << (8 * k)
    at += 4
    return v


def _rd_i32(d: List[UInt8], mut at: Int) raises -> Int:
    var v = _rd_u32(d, at)
    return v - (1 << 32) if v >= (1 << 31) else v


def _rd_u64(d: List[UInt8], mut at: Int) raises -> Int:
    _need(d, at, 8)
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(d[at + k]) << UInt64(8 * k)
    at += 8
    if v > UInt64(1 << 62):
        raise Error("vdb_grid: offset out of range")
    return Int(v)


def _rd_i64(d: List[UInt8], mut at: Int) raises -> Int:
    """A signed int64 (a negative value is a byte count, see _rd_stream_floats)."""
    _need(d, at, 8)
    var v = UInt64(0)
    for k in range(8):
        v |= UInt64(d[at + k]) << UInt64(8 * k)
    at += 8
    if v >> 63 != 0:
        return -Int((~v) + 1)
    if v > UInt64(1 << 62):
        raise Error("vdb_grid: byte count out of range")
    return Int(v)


def _rd_f32(d: List[UInt8], mut at: Int) raises -> Float32:
    _need(d, at, 4)
    var u = UInt32(0)
    for k in range(4):
        u |= UInt32(d[at + k]) << UInt32(8 * k)
    at += 4
    return Pointer(to=u).unsafe_bitcast[Float32]()[]


def _rd_f64(d: List[UInt8], mut at: Int) raises -> Float64:
    _need(d, at, 8)
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(d[at + k]) << UInt64(8 * k)
    at += 8
    return Pointer(to=u).unsafe_bitcast[Float64]()[]


def _rd_string(d: List[UInt8], mut at: Int) raises -> String:
    var n = _rd_u32(d, at)
    _need(d, at, n)
    var s = String(unsafe_from_utf8=Span(d)[at : at + n])
    at += n
    return s^


def _rd_mask(d: List[UInt8], mut at: Int, n: Int) raises -> List[Bool]:
    """n bits saved as n / 64 words; bit k of word w is entry 64 w + k."""
    _need(d, at, n // 8)
    var m = List[Bool](length=n, fill=False)
    for i in range(n):
        m[i] = (d[at + i // 8] >> UInt8(i % 8)) & 1 == 1
    at += n // 8
    return m^


def _skip_metadata(d: List[UInt8], mut at: Int) raises:
    var count = _rd_u32(d, at)
    for _ in range(count):
        _ = _rd_string(d, at)
        _ = _rd_string(d, at)
        var size = _rd_u32(d, at)
        _need(d, at, size)
        at += size


def _rd_stream_floats(d: List[UInt8], mut at: Int, count: Int, codec: Int) raises -> List[Float32]:
    """`count` floats as one value stream. `codec` 0 (raw): the floats follow
    raw. Otherwise (1 zip, 2 blosc) a signed int64 length first. Positive: that
    many bytes of compressed stream, decoding to count * 4 bytes. Zero or
    negative: the floats follow raw, and a negative length is the raw size as
    its negation (OpenVDB stores a stream raw when compression does not shrink
    it; a count of 0 is a length of 0)."""
    var out = List[Float32]()
    if codec == 0:
        for _ in range(count):
            out.append(_rd_f32(d, at))
        return out^
    var nbytes = _rd_i64(d, at)
    if nbytes <= 0:
        if nbytes < 0 and -nbytes != count * 4:
            raise Error("vdb_grid: raw value stream has the wrong size")
        for _ in range(count):
            out.append(_rd_f32(d, at))
        return out^
    _need(d, at, nbytes)
    var comp = List[UInt8](length=nbytes, fill=0)
    for i in range(nbytes):
        comp[i] = d[at + i]
    at += nbytes
    var raw = zlib_inflate(comp, count * 4) if codec == 1 else blosc_decode(comp, count * 4)
    if len(raw) != count * 4:
        raise Error("vdb_grid: compressed value stream has the wrong size")
    var p = 0
    for _ in range(count):
        out.append(_rd_f32(raw, p))
    return out^


def _rd_values(
    d: List[UInt8],
    mut at: Int,
    n: Int,
    active: List[Bool],
    mask_compressed: Bool,
    codec: Int,
    background: Float32,
) raises -> List[Float32]:
    """A node's value array as `io::readCompressedValues` reads it (no blosc,
    no half floats): metadata byte, optional inactive values and selection
    mask, then the active values only or all n, framed by `codec` (0 raw, 1 zip,
    2 blosc)."""
    _need(d, at, 1)
    var meta = Int(d[at])
    at += 1
    if meta > 6:
        raise Error("vdb_grid: bad value metadata byte")
    var in0 = background
    var in1 = background
    if meta == 1:
        in0 = -background
    if meta == 2 or meta == 4 or meta == 5:
        in0 = _rd_f32(d, at)
    if meta == 3:
        in0 = background
        in1 = -background
    if meta == 5:
        in1 = _rd_f32(d, at)
    var sel = List[Bool]()
    if meta == 3 or meta == 4 or meta == 5:
        sel = _rd_mask(d, at, n)
    var out = List[Float32](length=n, fill=in0)
    if mask_compressed and meta != 6:
        var nact = 0
        for i in range(n):
            if active[i]:
                nact += 1
        var vals = _rd_stream_floats(d, at, nact, codec)
        var j = 0
        for i in range(n):
            if active[i]:
                out[i] = vals[j]
                j += 1
            elif len(sel) > 0 and sel[i]:
                out[i] = in1
    else:
        var vals = _rd_stream_floats(d, at, n, codec)
        for i in range(n):
            out[i] = vals[i]
    return out^


def vdb_grid(d: List[UInt8]) raises -> VdbGrid:
    """Read the first grid of a `.vdb` file (file version 224 or 225) into a
    `SparseVolume`: what `vdb_bytes` writes, and any FloatGrid in the 5-4-3
    configuration stored raw, zip-compressed, or blosc-compressed (LZ4), with
    or without the active mask, and without half floats. Raises on a wrong
    magic or version, another grid type or transform, root-level tiles (not
    implemented), offsets that do not match the
    stream, and truncation. Active tiles below the root (8^3 and 128^3) are
    expanded to their voxels. Inactive values read as the background (a level
    set's inside value is lost)."""
    var at = 0
    if _rd_u64(d, at) != 0x56444220:
        raise Error("vdb_grid: not a .vdb file (magic)")
    var version = _rd_u32(d, at)
    if version != 224 and version != 225:
        raise Error("vdb_grid: unsupported file version " + String(version))
    _ = _rd_u32(d, at)
    _ = _rd_u32(d, at)
    _need(d, at, 37)
    if d[at] != 1:
        raise Error("vdb_grid: files without grid offsets are not supported")
    at += 37  # offsets flag + UUID
    _skip_metadata(d, at)
    if _rd_u32(d, at) < 1:
        raise Error("vdb_grid: no grids")
    var name = _rd_string(d, at)
    var gtype = _rd_string(d, at)
    if gtype != "Tree_float_5_4_3":
        raise Error("vdb_grid: grid type " + gtype + " (only Tree_float_5_4_3)")
    if _rd_string(d, at) != "":
        raise Error("vdb_grid: instanced grids are not supported")
    var grid_pos = _rd_u64(d, at)
    var block_pos = _rd_u64(d, at)
    var end_pos = _rd_u64(d, at)
    if grid_pos != at or not (grid_pos < block_pos and block_pos <= end_pos and end_pos <= len(d)):
        raise Error("vdb_grid: grid offsets do not match the stream")
    var compression = _rd_u32(d, at)
    var mc = compression & 2 != 0
    var codec = 0  # 0 raw, 1 zip, 2 blosc
    if compression == 1 or compression == 3:
        codec = 1
    elif compression == 4 or compression == 6:
        codec = 2
    elif compression != 0 and compression != 2:
        raise Error("vdb_grid: compression " + String(compression) + " is not supported")
    _skip_metadata(d, at)
    var map_type = _rd_string(d, at)
    if map_type != "UniformScaleMap":
        raise Error("vdb_grid: transform " + map_type + " (only UniformScaleMap)")
    var voxel_size = _rd_f64(d, at)
    at += 14 * 8
    _need(d, at, 0)
    if _rd_u32(d, at) != 1:
        raise Error("vdb_grid: buffer count must be 1")
    var bg = _rd_f32(d, at)
    var vol = SparseVolume(Real(bg))
    var tiles = _rd_u32(d, at)
    var kids = _rd_u32(d, at)
    for _ in range(tiles):
        _ = _rd_i32(d, at)
        _ = _rd_i32(d, at)
        _ = _rd_i32(d, at)
        var v = _rd_f32(d, at)
        _need(d, at, 1)
        var on = d[at] != 0
        at += 1
        if on or v != bg:
            raise Error("vdb_grid: root tiles are not supported")
    # topology: collect the leaf origins and value masks in stream order
    var lo = List[Int]()  # x, y, z per leaf
    var lmasks = List[List[Bool]]()
    # active tiles: a 128^3 tile (value mask of a root child's 32^3 node) or an
    # 8^3 tile (value mask of a 128^3 node), expanded to voxels after the leaves
    var act_at = List[Int]()  # x, y, z of each tile's origin, three per tile
    var act_side = List[Int]()
    var act_val = List[Float32]()
    for _ in range(kids):
        var tx = _rd_i32(d, at)
        var ty = _rd_i32(d, at)
        var tz = _rd_i32(d, at)
        var cm = _rd_mask(d, at, 32768)
        var vm = _rd_mask(d, at, 32768)
        for k in range(32768):
            if vm[k] and cm[k]:
                raise Error("vdb_grid: a node is both a child and a tile")
        var tv = _rd_values(d, at, 32768, vm, mc, codec, bg)
        for k in range(32768):
            if vm[k]:
                act_at.append(tx + (((k >> 10) & 31) << 7))
                act_at.append(ty + (((k >> 5) & 31) << 7))
                act_at.append(tz + ((k & 31) << 7))
                act_side.append(128)
                act_val.append(tv[k])
        for k in range(32768):
            if not cm[k]:
                continue
            var mx = tx + (((k >> 10) & 31) << 7)
            var my = ty + (((k >> 5) & 31) << 7)
            var mz = tz + ((k & 31) << 7)
            var cm2 = _rd_mask(d, at, 4096)
            var vm2 = _rd_mask(d, at, 4096)
            for q in range(4096):
                if vm2[q] and cm2[q]:
                    raise Error("vdb_grid: a node is both a child and a tile")
            var tv2 = _rd_values(d, at, 4096, vm2, mc, codec, bg)
            for q in range(4096):
                if vm2[q]:
                    act_at.append(mx + (((q >> 8) & 15) << 3))
                    act_at.append(my + (((q >> 4) & 15) << 3))
                    act_at.append(mz + ((q & 15) << 3))
                    act_side.append(8)
                    act_val.append(tv2[q])
            for q in range(4096):
                if not cm2[q]:
                    continue
                lo.append(mx + (((q >> 8) & 15) << 3))
                lo.append(my + (((q >> 4) & 15) << 3))
                lo.append(mz + ((q & 15) << 3))
                lmasks.append(_rd_mask(d, at, 512))
    if at != block_pos:
        raise Error("vdb_grid: topology does not end at the block offset")
    for li in range(len(lmasks)):
        var m = _rd_mask(d, at, 512)
        for o in range(512):
            if m[o] != lmasks[li][o]:
                raise Error("vdb_grid: leaf buffer mask differs from its topology mask")
        var vals = _rd_values(d, at, 512, m, mc, codec, bg)
        for o in range(512):
            if m[o]:
                vol.set(lo[3 * li] + (o >> 6), lo[3 * li + 1] + ((o >> 3) & 7), lo[3 * li + 2] + (o & 7), Real(vals[o]))
    # active tiles: a constant cube of voxels, expanded to the voxels it covers
    for t in range(len(act_side)):
        var side = act_side[t]
        var ox = act_at[3 * t]
        var oy = act_at[3 * t + 1]
        var oz = act_at[3 * t + 2]
        for x in range(side):
            for y in range(side):
                for z in range(side):
                    vol.set(ox + x, oy + y, oz + z, Real(act_val[t]))
    if at != end_pos:
        raise Error("vdb_grid: buffers do not end at the end offset")
    return VdbGrid(name^, voxel_size, vol^)
