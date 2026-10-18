#!/usr/bin/env python3
"""Check `.vdb` files written by `geometry.vdb_file` with OpenVDB's reader (ROADMAP 17.63).

`tests/test_vdb_file.mojo` writes `build/vdb/<name>.vdb` and `<name>.txt`
(every active voxel as `x y z value`, the value as f32 bits in hex), each volume twice: `<name>.vdb`
with active-mask values and `<name>_raw.vdb` with every value. For each pair this opens the `.vdb`
with the `openvdb` Python module (conda-forge, not in the project
environment; `pixi run vdb-check` runs it through `pixi exec`) and compares:

  - one FloatGrid, its name equal to the file stem;
  - the active voxel count;
  - every active voxel's coordinate and value (f32, exact);
  - the background value, the voxel size and a far-away voxel reading the
    background, for the stems listed in EXPECTED.

Usage: vdb_check.py [DIR]   (default build/vdb). Exit status 1 on any
mismatch, 2 if `openvdb` is not importable.
"""

import struct
import sys
from pathlib import Path

# background and voxel size per file stem, as test_vdb_file sets them
EXPECTED = {  # keyed by stem without "_raw"
    "sphere": (3.0, 0.1),
    "far": (0.0, 0.5),
    "empty": (1.0, 1.0),
}


def f32(v: float) -> float:
    return struct.unpack("<f", struct.pack("<f", v))[0]


def check(vdb_path: Path, txt_path: Path, vdb) -> list[str]:
    errs: list[str] = []
    grids = vdb.readAllGridMetadata(str(vdb_path))
    if len(grids) != 1:
        return [f"{vdb_path.name}: {len(grids)} grids, want 1"]
    grid = vdb.read(str(vdb_path), vdb_path.stem)
    if grid.name != vdb_path.stem:
        errs.append(f"{vdb_path.name}: grid name {grid.name!r}")
    if type(grid).__name__ != "FloatGrid":
        errs.append(f"{vdb_path.name}: grid type {type(grid).__name__}")
    want: dict[tuple[int, int, int], float] = {}
    for line in txt_path.read_text().splitlines():
        x, y, z, v = line.split()
        want[(int(x), int(y), int(z))] = struct.unpack("<f", struct.pack("<I", int(v, 16)))[0]
    got: dict[tuple[int, int, int], float] = {}
    for it in grid.citerOnValues():
        if it.count != 1:
            errs.append(f"{vdb_path.name}: active tile at {it.min} (count {it.count}), want voxels only")
            continue
        got[tuple(it.min)] = it.value
    if grid.activeVoxelCount() != len(want):
        errs.append(f"{vdb_path.name}: activeVoxelCount {grid.activeVoxelCount()}, want {len(want)}")
    missing = [k for k in want if k not in got]
    extra = [k for k in got if k not in want]
    wrong = [k for k in want if k in got and got[k] != want[k]]
    if missing:
        errs.append(f"{vdb_path.name}: {len(missing)} voxels missing, e.g. {missing[:3]}")
    if extra:
        errs.append(f"{vdb_path.name}: {len(extra)} extra voxels, e.g. {extra[:3]}")
    if wrong:
        k = wrong[0]
        errs.append(f"{vdb_path.name}: {len(wrong)} values differ, e.g. {k}: {got[k]} vs {want[k]}")
    acc = grid.getConstAccessor()
    for k, v in want.items():
        if acc.getValue(k) != v:
            errs.append(f"{vdb_path.name}: accessor value at {k} is {acc.getValue(k)}, want {v}")
            break
    base = vdb_path.stem.removesuffix("_raw")
    if base in EXPECTED:
        bg, vs = EXPECTED[base]
        if grid.background != f32(bg):
            errs.append(f"{vdb_path.name}: background {grid.background}, want {bg}")
        size = grid.transform.voxelSize()
        if any(abs(c - vs) > 1e-12 for c in size):
            errs.append(f"{vdb_path.name}: voxel size {size}, want {vs}")
        if acc.getValue((10**6, 10**6, 10**6)) != f32(bg):
            errs.append(f"{vdb_path.name}: far-away voxel does not read the background")
    print(
        f"{vdb_path.name}: {len(got)} active voxels, {grid.leafCount()} leaves, "
        f"background {grid.background}, voxel size {grid.transform.voxelSize()[0]}: "
        f"{'ok' if not errs else 'MISMATCH'}"
    )
    return errs


def main() -> int:
    d = Path(sys.argv[1] if len(sys.argv) > 1 else "build/vdb")
    try:
        import openvdb as vdb  # type: ignore[import-not-found]
    except ImportError:
        try:
            import pyopenvdb as vdb  # type: ignore[import-not-found,no-redef]
        except ImportError:
            print("vdb_check: the openvdb Python module is not importable", file=sys.stderr)
            return 2
    print(f"openvdb {vdb.LIBRARY_VERSION}")
    files = sorted(d.glob("*.vdb"))
    if not files:
        print(f"vdb_check: no .vdb files in {d} (run tests/test_vdb_file.mojo first)", file=sys.stderr)
        return 1
    errs: list[str] = []
    for f in files:
        errs += check(f, f.with_suffix(".txt"), vdb)
    for e in errs:
        print("  " + e)
    print(f"vdb_check: {len(files)} files, {'OK' if not errs else f'{len(errs)} mismatches'}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
