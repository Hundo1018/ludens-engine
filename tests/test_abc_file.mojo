# tier: unit
"""Alembic (Ogawa) files (ROADMAP 17.63, `geometry.abc_file`).

  1. Ordinary: a 5 x 5-vertex cloth (16 quads) waving for 12 frames at
     24 fps. The file starts with the Ogawa header, its root offset points
     inside it; the bytes are hashed (FNV-1a) so the golden pins the file.
     Topology given once per frame but equal every frame is stored once:
     the 12-frame file is printed next to a 1-frame one.
  2. Integration: the files land in `build/abc/` with a text list of what
     was written (`scripts/abc_check.py` documents it); `pixi run
     abc-check` imports each with Blender's Alembic importer and compares
     every frame's positions, faces and curve / point counts. Besides the
     cloth: a mesh whose topology changes every frame (a fan gaining a
     triangle per frame), particles whose count changes (ids kept), and
     three swaying strands as linear curves.
  3. Extreme: an archive with no objects and an object with no frames
     still write; bad input raises (face index out of range, counts not
     adding up, a 1-vertex curve, missing ids, duplicate or empty names,
     wrong object kind, fps 0).
"""

from std.math import sin, cos
from std.os import makedirs
from harness.runner import Suite
from geometry.vec import Real
from geometry.abc_file import AbcArchive


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


def _header_ok(b: List[UInt8]) -> Bool:
    if len(b) < 16:
        return False
    var magic = "Ogawa".as_bytes()
    for i in range(5):
        if b[i] != magic[i]:
            return False
    var root = _u64_at(b, 8)
    return b[5] == 0xFF and b[6] == 0 and b[7] == 1 and root >= 16 and root + 8 <= len(b)


def _save(path: String, b: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(b))


def _p(head: String, pos: List[Real]) -> String:
    var s = head
    for i in range(len(pos) // 3):
        s += "p"
        for c in range(3):
            var x = Float32(pos[3 * i + c])
            s += " " + hex(Pointer(to=x).unsafe_bitcast[UInt32]()[])
        s += "\n"
    return s^


def _cloth(t: Int) -> List[Real]:
    var pos = List[Real]()
    for j in range(5):
        for i in range(5):
            var x = Real(i) * 0.25
            var z = Real(j) * 0.25
            pos.append(x)
            pos.append(0.1 * sin(Real(2) * x + Real(0.4) * Real(t)) * cos(Real(3) * z))
            pos.append(z)
    return pos^


def _quads(mut counts: List[Int], mut idx: List[Int]):
    for j in range(4):
        for i in range(4):
            var a = j * 5 + i
            counts.append(4)
            idx.append(a)
            idx.append(a + 1)
            idx.append(a + 6)
            idx.append(a + 5)


def _raises_mesh(mut a: AbcArchive, obj: Int, pos: List[Real], c: List[Int], i: List[Int]) -> Bool:
    try:
        a.mesh_frame(obj, pos, c, i)
    except:
        return True
    return False


def main() raises:
    var s = Suite("abc_file")
    var dir = "build/abc"
    makedirs(dir, exist_ok=True)
    var counts = List[Int]()
    var idx = List[Int]()
    _quads(counts, idx)

    # 1. waving cloth, 12 frames
    var a = AbcArchive(24, 0)
    var cloth = a.add_mesh("cloth")
    var txt = String("o cloth mesh\n")
    for t in range(12):
        var pos = _cloth(t)
        a.mesh_frame(cloth, pos, counts, idx)
        txt += "t " + String(t) + "\n"
        txt = _p(txt, pos)
        var at = 0
        for c in counts:
            txt += "f"
            for k in range(c):
                txt += " " + String(idx[at + k])
            txt += "\n"
            at += c
    var b = a.bytes()
    s.check(_header_ok(b), "cloth: Ogawa header, frozen, version 1, root offset inside the file")
    s.check(_fnv(a.bytes()) == _fnv(b), "same archive, same bytes")
    var one = AbcArchive(24, 0)
    var c1 = one.add_mesh("cloth")
    one.mesh_frame(c1, _cloth(0), counts, idx)
    var b1 = one.bytes()
    print("  cloth: 25 vertices, 16 quads; 12 frames", len(b), "bytes, 1 frame", len(b1), "bytes; fnv1a", hex(_fnv(b)))
    # 11 more frames add positions (12 B per vertex + key + block) and bounds, not topology
    var per_frame = (len(b) - len(b1)) // 11
    print("  cloth: bytes per extra frame", per_frame, "(positions 300 B)")
    s.check(per_frame < 300 + 200, "constant topology is stored once (extra frame < positions + 200 B)")
    _save(dir + "/cloth.abc", b)
    with open(dir + "/cloth.txt", "w") as f:
        f.write(txt)

    # 2. topology changes every frame: a fan with t + 1 triangles
    var g = AbcArchive(24, 0)
    var fan = g.add_mesh("fan")
    var ftxt = String("o fan mesh\n")
    for t in range(8):
        var pos: List[Real] = [0, 0, 0]
        var fc = List[Int]()
        var fi = List[Int]()
        for k in range(t + 2):
            var ang = Real(0.5) * Real(k)
            pos.append(cos(ang))
            pos.append(Real(0.05) * Real(t))
            pos.append(sin(ang))
        for k in range(t + 1):
            fc.append(3)
            fi.append(0)
            fi.append(k + 1)
            fi.append(k + 2)
        g.mesh_frame(fan, pos, fc, fi)
        ftxt += "t " + String(t) + "\n"
        ftxt = _p(ftxt, pos)
        for k in range(t + 1):
            ftxt += "f 0 " + String(k + 1) + " " + String(k + 2) + "\n"
    var bg = g.bytes()
    s.check(_header_ok(bg), "fan: header")
    print("  fan: 8 frames, 1..8 triangles,", len(bg), "bytes; fnv1a", hex(_fnv(bg)))
    _save(dir + "/fan.abc", bg)
    with open(dir + "/fan.txt", "w") as f:
        f.write(ftxt)

    # particles whose count changes; strands as linear curves
    var h = AbcArchive(24, 0)
    var pts = h.add_points("spray")
    var hair = h.add_curves("hair")
    var ptxt = String("o spray points\n")
    var htxt = String("o hair curves\n")
    for t in range(6):
        var pos = List[Real]()
        var ids = List[Int]()
        for k in range(3 + 2 * t):
            pos.append(Real(0.1) * Real(k))
            pos.append(Real(1) - Real(0.02) * Real(t * t))
            pos.append(Real(0.05) * Real(t))
            ids.append(100 + k)
        h.points_frame(pts, pos, ids)
        ptxt += "t " + String(t) + "\n"
        ptxt = _p(ptxt, pos)
        var cp = List[Real]()
        var cc: List[Int] = [4, 4, 4]
        for strand in range(3):
            for v in range(4):
                cp.append(Real(strand) * 0.2 + Real(0.03) * Real(v) * sin(Real(0.5) * Real(t)))
                cp.append(-Real(0.1) * Real(v))
                cp.append(0)
        h.curves_frame(hair, cp, cc)
        htxt += "t " + String(t) + "\n"
        htxt = _p(htxt, cp)
        htxt += "c 4 4 4\n"
    var bh = h.bytes()
    s.check(_header_ok(bh), "points + curves: header")
    print("  spray + hair: 6 frames, 3..13 points, 3 strands x 4,", len(bh), "bytes; fnv1a", hex(_fnv(bh)))
    _save(dir + "/spray_hair.abc", bh)
    with open(dir + "/spray_hair.txt", "w") as f:
        f.write(ptxt + htxt)

    # 3. extremes
    var e = AbcArchive()
    var be = e.bytes()
    s.check(_header_ok(be), "no objects: still a valid header")
    var z = AbcArchive()
    _ = z.add_mesh("nothing")
    s.check(_header_ok(z.bytes()), "an object with no frames writes")
    print("  empty archive", len(be), "bytes")
    var bad = AbcArchive()
    var m = bad.add_mesh("m")
    var tri: List[Real] = [0, 0, 0, 1, 0, 0, 0, 1, 0]
    var c3: List[Int] = [3]
    var i_oob: List[Int] = [0, 1, 3]
    var i_short: List[Int] = [0, 1]
    s.check(_raises_mesh(bad, m, tri, c3, i_oob), "vertex index out of range raises")
    s.check(_raises_mesh(bad, m, tri, c3, i_short), "face counts not adding up raises")
    var r = 0
    try:
        _ = bad.add_mesh("m")
    except:
        r += 1
    try:
        _ = bad.add_points("")
    except:
        r += 1
    var cv = bad.add_curves("c")
    try:
        var one_v: List[Int] = [1, 2]
        bad.curves_frame(cv, tri, one_v)
    except:
        r += 1
    var pv = bad.add_points("p")
    try:
        var two: List[Int] = [1, 2]
        bad.points_frame(pv, tri, two)
    except:
        r += 1
    try:
        var ids3: List[Int] = [1, 2, 3]
        bad.points_frame(m, tri, ids3)
    except:
        r += 1
    try:
        _ = AbcArchive(0)
    except:
        r += 1
    s.check(r == 6, "duplicate / empty name, 1-vertex curve, missing ids, wrong kind, fps 0 raise")
    s.finish()
