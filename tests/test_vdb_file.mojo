# tier: component
"""OpenVDB files from sparse volumes (ROADMAP 17.63, `geometry.vdb_file`).

  1. Ordinary: a sphere's narrow-band signed distance (radius 10 voxels,
     centre (-3, 2, 5), band 3 voxels, background 3) written as a FloatGrid.
     Each volume is written twice, with active-mask values (`name.vdb`)
     and with every value (`name_raw.vdb`); the sizes are printed. The
     stream offsets in the grid descriptor point inside the buffer and the
     last one is its length; the bytes are hashed (FNV-1a) so the golden
     pins the exact files.
  2. Integration: the files land in `build/vdb/` with a text list of every
     active voxel (`x y z f32-bits`); `pixi run vdb-check` opens each `.vdb`
     with OpenVDB's own reader (`scripts/vdb_check.py`) and compares the
     active voxel count, every value, the background and the voxel size.
     `vdb_grid` reads every file back: name, voxel size, leaf count and
     every active voxel equal.
  3. Extreme: a volume spread over four root children (x = -4097, -5,
     130 and 4100) and several 128^3 nodes; an empty volume (a grid with no
     children); voxel size 0 raises; a wrong magic, an unknown version,
     nine truncation points, the blosc bit and a block offset that does not
     match the stream raise; bytes after the grid's end are not read.
"""

from std.math import sqrt
from std.os import makedirs
from harness.runner import Suite
from geometry.vec import Real
from geometry.sparse_volume import SparseVolume, LEAF
from geometry.vdb_file import vdb_bytes, vdb_grid


def _fnv(b: List[UInt8]) -> UInt64:
    var h = UInt64(0xCBF29CE484222325)
    for c in b:
        h = (h ^ UInt64(c)) * UInt64(0x100000001B3)
    return h


def _u64_at(b: List[UInt8], at: Int) -> Int:
    var v = 0
    for k in range(8):
        v |= Int(b[at + k]) << (8 * k)
    return v


def _offsets_ok(b: List[UInt8], name: String) -> Bool:
    """grid_pos < block_pos <= end_pos == len(b), read from the descriptor
    (block_pos == end_pos when there are no leaves)."""
    # header 8 + 4 + 4 + 4 + 1 + 36, metadata 4, grid count 4
    var at = 65
    at += 4 + len(name.as_bytes())
    at += 4 + 16  # "Tree_float_5_4_3"
    at += 4
    var g = _u64_at(b, at)
    var k = _u64_at(b, at + 8)
    var e = _u64_at(b, at + 16)
    return g == at + 24 and g < k and k <= e and e == len(b)


def _save(path: String, b: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(b))


def _dump(path: String, vol: SparseVolume) raises:
    """Every active voxel as `x y z value`, the value as its f32 bit pattern
    (hex): `String(Float32)` does not always read back to the same f32."""
    var out = String()
    for ref lf in vol.leaves:
        for o in range(LEAF * LEAF * LEAF):
            if not lf.mask[o]:
                continue
            var x = lf.ox + o % LEAF
            var y = lf.oy + (o // LEAF) % LEAF
            var z = lf.oz + o // (LEAF * LEAF)
            var v = Float32(lf.val[o])
            out += String(x) + " " + String(y) + " " + String(z) + " " + hex(Pointer(to=v).unsafe_bitcast[UInt32]()[]) + "\n"
    with open(path, "w") as f:
        f.write(out)


def _both(mut s: Suite, dir: String, stem: String, vol: SparseVolume, voxel_size: Float64) raises:
    """Write `stem.vdb` (active-mask values) and `stem_raw.vdb` (all
    values), each with its voxel list, and print sizes and hashes."""
    for raw in range(2):
        var name = stem + ("_raw" if raw == 1 else "")
        var b = vdb_bytes(vol, name, voxel_size, active_mask=raw == 0)
        s.check(_offsets_ok(b, name), name + ": descriptor offsets, grid < blocks <= end == length")
        print("  " + name + ": bytes", len(b), "fnv1a", hex(_fnv(b)))
        _save(dir + "/" + name + ".vdb", b)
        _dump(dir + "/" + name + ".txt", vol)
        var g = vdb_grid(b)
        s.check(g.name == name and g.voxel_size == voxel_size, name + ": read back name and voxel size")
        s.check(_same(vol, g.volume), name + ": read back, every active voxel equal, same leaf count")


def _same(a: SparseVolume, b: SparseVolume) -> Bool:
    if a.active_voxels() != b.active_voxels() or a.leaf_count() != b.leaf_count() or a.background != b.background:
        return False
    for ref lf in a.leaves:
        for o in range(LEAF * LEAF * LEAF):
            if lf.mask[o]:
                var x = lf.ox + o % LEAF
                var y = lf.oy + (o // LEAF) % LEAF
                var z = lf.oz + o // (LEAF * LEAF)
                if b.get(x, y, z) != lf.val[o]:
                    return False
    return True


def _raises(b: List[UInt8]) -> Bool:
    try:
        _ = vdb_grid(b)
    except:
        return True
    return False


def main() raises:
    var s = Suite("vdb_file")
    var dir = "build/vdb"
    makedirs(dir, exist_ok=True)

    # 1. narrow-band sphere
    var sph = SparseVolume(3)
    for z in range(-10, 21):
        for y in range(-13, 18):
            for x in range(-18, 13):
                var dx = Real(x + 3)
                var dy = Real(y - 2)
                var dz = Real(z - 5)
                var d = sqrt(dx * dx + dy * dy + dz * dz) - 10
                if abs(d) < 3:
                    sph.set(x, y, z, d)
    print("  sphere: active voxels", sph.active_voxels(), "leaves", sph.leaf_count())
    _both(s, dir, "sphere", sph, 0.1)
    var b = vdb_bytes(sph, "sphere", 0.1)
    s.check(_fnv(vdb_bytes(sph, "sphere", 0.1)) == _fnv(b), "same volume, same bytes")

    # 3. spread over two root children and several internal nodes
    var far = SparseVolume(0)
    far.set(-5, 0, 0, 1.5)
    far.set(4100, 0, 0, -2.25)
    far.set(130, -129, 7, 0.75)
    far.set(127, 127, 127, 4)
    far.set(-4097, 3, -1, 8)
    print("  far: active voxels", far.active_voxels(), "leaves", far.leaf_count())
    _both(s, dir, "far", far, 0.5)
    _both(s, dir, "empty", SparseVolume(1), 1)

    var raised = False
    try:
        _ = vdb_bytes(sph, "bad", 0)
    except:
        raised = True
    s.check(raised, "voxel size 0 raises")

    # malformed files raise instead of reading past the end
    var bad = b.copy()
    bad[0] = 0
    s.check(_raises(bad), "wrong magic raises")
    bad = b.copy()
    bad[8] = 226
    s.check(_raises(bad), "unknown file version raises")
    var cuts = 0
    for cut in [0, 7, 40, 100, 200, 300, 5000, len(b) // 2, len(b) - 1]:
        var t = List[UInt8]()
        for i in range(cut):
            t.append(b[i])
        if _raises(t):
            cuts += 1
    s.check(cuts == 9, "9 truncation points all raise")
    # the compression word follows the three offsets; set the blosc bit (zip
    # is read by test_vdb_zip)
    var blosc = b.copy()
    var cpos = 65 + 4 + len("sphere".as_bytes()) + 4 + 16 + 4 + 24
    blosc[cpos] = blosc[cpos] | 4
    s.check(_raises(blosc), "blosc compression raises (not supported)")
    var tail = b.copy()
    tail.append(0)
    s.check(not _raises(tail), "bytes after the grid's end offset are not read")
    var off = b.copy()
    off[cpos - 16] = off[cpos - 16] ^ 8  # block offset moved by 8
    s.check(_raises(off), "a block offset that does not match the stream raises")
    s.finish()
