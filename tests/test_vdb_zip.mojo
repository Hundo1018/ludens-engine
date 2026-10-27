# tier: unit
"""Zip-compressed `.vdb` read (ROADMAP 17.63, `geometry.vdb_file.vdb_grid`).

Four OpenVDB 13.1 files in tests/data/vdb/, written by scripts/zipwrite_fixtures.cc:
the same grid stored raw (the control), zip, zip with the active mask, and a
hashed-noise grid under zip. Two balls of active voxels: radius 6 around
(20,20,20) (925 voxels) and radius 2 around (200,20,20) (33 voxels), 958 in all.
The values are the generator's formulas, so every active voxel is checked against
them. Each file is read through `vdb_grid`; a truncated zip file raises.
"""

from harness.runner import Suite
from geometry.vdb_file import vdb_grid


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _smooth(i: Int, j: Int, k: Int) -> Float64:
    return 1.0 + 0.001 * Float64(i + j + k)


def _noise(i: Int, j: Int, k: Int) -> Float64:
    var h = (i * 73856093) ^ (j * 19349663) ^ (k * 83492791)
    return Float64(h & 0xFFFF) / 65536.0


def _inside(i: Int, j: Int, k: Int, cx: Int, cy: Int, cz: Int, r: Int) -> Bool:
    var dx = i - cx
    var dy = j - cy
    var dz = k - cz
    return dx * dx + dy * dy + dz * dz <= r * r


def _grid_ok(d: List[UInt8], noisy: Bool) raises -> Tuple[Bool, Int, Float64]:
    """(all active voxels match the formula and the count is 958, voxels that
    differ, worst absolute difference)."""
    var g = vdb_grid(d)
    var n = 0
    var bad = 0
    var worst = 0.0
    for c in range(2):
        var cx = 20 if c == 0 else 200
        var r = 6 if c == 0 else 2
        for i in range(cx - r, cx + r + 1):
            for j in range(20 - r, 20 + r + 1):
                for k in range(20 - r, 20 + r + 1):
                    if not _inside(i, j, k, cx, 20, 20, r):
                        continue
                    n += 1
                    var want = _noise(i, j, k) if noisy else _smooth(i, j, k)
                    var diff = abs(Float64(g.volume.get(i, j, k)) - want)
                    if diff > worst:
                        worst = diff
                    if diff > 1e-5:
                        bad += 1
    var ok = g.volume.active_voxels() == 958 and n == 958 and bad == 0
    return (ok, bad, worst)


def main() raises:
    var s = Suite("vdb_zip")
    var root = "tests/data/vdb/"

    var raw = _grid_ok(_read(root + "raw_smooth.vdb"), False)
    s.check(raw[0], "raw control: 958 active voxels, all values match")

    var zip = _grid_ok(_read(root + "zip_smooth.vdb"), False)
    s.check(zip[0], "zip: 958 active voxels, all values match")

    var mask = _grid_ok(_read(root + "zip_mask_smooth.vdb"), False)
    s.check(mask[0], "zip with active mask: 958 active voxels, all values match")

    var noise = _grid_ok(_read(root + "zip_noise.vdb"), True)
    s.check(noise[0], "zip of hashed noise: 958 active voxels, all values match")

    var g = vdb_grid(_read(root + "zip_smooth.vdb"))
    s.check(g.name == "field", "zip grid keeps its name")
    s.almost(g.voxel_size, 0.1, "zip grid voxel size is 0.1", tol=1e-9)

    # a zip file cut short must raise, not read past its end
    var cut = _read(root + "zip_smooth.vdb")
    var short = List[UInt8]()
    for i in range(len(cut) - 1):
        short.append(cut[i])
    var raised = False
    try:
        _ = vdb_grid(short)
    except:
        raised = True
    s.check(raised, "a zip file one byte short raises")
    s.finish()
