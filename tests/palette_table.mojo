"""app/palette_table.mojo (ludens-engine#71): 100 instances over 8 distinct poses of 19 matrices store 8 poses (152
matrices), each instance's base is its pose's; unshared poses are always added; a pose past the capacity is refused and
counted; begin empties the table; a duplicate key and a bad pose raise."""
from harness.runner import Suite
from app.palette_table import PaletteTable


def pose(tag: Int, joints: Int) -> List[Float32]:
    var out = List[Float32]()
    for j in range(joints):
        for k in range(16):
            out.append(Float32(tag * 1000 + j * 16 + k))
    return out^


def main() raises:
    var s = Suite("palette_table")
    var t = PaletteTable(4096)
    t.begin()
    var bases = List[Int]()
    for i in range(100):
        var key = i % 8
        var b = t.find(key)
        if b < 0:
            b = t.add(key, pose(key, 19))
        bases.append(b)
    s.check(t.matrices() == 8 * 19, "8 distinct poses stored: " + String(t.matrices()) + " matrices")
    s.check(t.shared == 92, "92 instances share a stored pose (" + String(t.shared) + ")")
    var right = True
    for i in range(100):
        var b = bases[i]
        right = right and t.palette[b * 16] == Float32((i % 8) * 1000)
    s.check(right, "every instance's base points at its own pose's first matrix")
    var u1 = t.add(-1, pose(50, 19))
    var u2 = t.add(-1, pose(50, 19))
    s.check(u1 >= 0 and u2 >= 0 and u1 != u2 and t.find(-1) == -1, "unshared poses are always added, never found")
    var small = PaletteTable(40)
    small.begin()
    var a = small.add(1, pose(1, 19))
    var b = small.add(2, pose(2, 19))
    var c = small.add(3, pose(3, 19))
    s.check(a == 0 and b == 19 and c == -1 and small.dropped == 1, "the third 19-matrix pose does not fit 40 matrices: refused, counted")
    small.begin()
    s.check(small.matrices() == 0 and small.dropped == 0 and small.find(1) == -1, "begin empties the table")
    var raised = 0
    try:
        _ = small.add(1, pose(1, 1))
        _ = small.add(1, pose(1, 1))
    except:
        raised += 1
    try:
        var bad = List[Float32]()
        bad.append(1.0)
        _ = small.add(9, bad)
    except:
        raised += 1
    s.check(raised == 2, "a duplicate key and a pose that is not 16 floats per matrix raise")
    s.finish()
