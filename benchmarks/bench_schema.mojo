"""Reflection-driven vs hand-written serialisation (ROADMAP 17.11 seam).

The schema writer is self-describing: every field carries its name, type
name and size, so a record can be read by a later version of the type. The
hand-written partner writes the same fields as bare floats in a fixed order
and cannot. The rows price that: bytes per Transform and ns per Transform for
write and for read, over N components. The batch form (`write_values` / `read_values`) writes the
field descriptors once per batch and matches names once, which is where the
single-value form's overhead goes.
"""

from std.benchmark import keep
from std.time import perf_counter_ns
from harness.bench import BenchTable
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from ecs.transform import Transform
from ecs.schema import schema_of, write_value, read_value, write_values, read_values

comptime REPS = 5


def _hand_write(t: Transform, mut out: List[Float32]):
    for k in range(3):
        out.append(t.translation[k])
    out.append(t.rotation.x)
    out.append(t.rotation.y)
    out.append(t.rotation.z)
    out.append(t.rotation.w)
    for k in range(3):
        out.append(t.scale[k])
    out.append(Float32(1) if t.local_dirty else Float32(0))
    out.append(Float32(1) if t.world_dirty else Float32(0))


def _hand_read(src: List[Float32], mut pos: Int) -> Transform:
    var t = Transform.at(Vec3(src[pos], src[pos + 1], src[pos + 2], 0))
    t.rotation = Quat(src[pos + 3], src[pos + 4], src[pos + 5], src[pos + 6])
    t.scale = Vec3(src[pos + 7], src[pos + 8], src[pos + 9], 0)
    t.local_dirty = src[pos + 10] != 0
    t.world_dirty = src[pos + 11] != 0
    pos += 12
    return t


def _rows(mut t: BenchTable, n: Int) raises:
    var ts = schema_of[Transform]()
    var vals = List[Transform]()
    for i in range(n):
        vals.append(Transform.at(Vec3(Real(i), 1, 2, 0)))

    var bw = Int.MAX
    var br = Int.MAX
    var nbytes = 0
    for _ in range(REPS):
        var blob = List[UInt8]()
        var t0 = Int(perf_counter_ns())
        for i in range(n):
            write_value(vals[i], ts, blob)
        bw = min(bw, Int(perf_counter_ns()) - t0)
        nbytes = len(blob)
        var pos = 0
        var t1 = Int(perf_counter_ns())
        for _ in range(n):
            var v = Transform.at(Vec3(0, 0, 0, 0))
            _ = read_value(v, ts, blob, pos)
            keep(v.translation[0])
        br = min(br, Int(perf_counter_ns()) - t1)
    t.add("schema write (" + String(nbytes // n) + " B/value)", n, "value", bw, n)
    t.add("schema read", n, "value", br, n)

    var cw = Int.MAX
    var cr = Int.MAX
    var cbytes = 0
    for _ in range(REPS):
        var blob = List[UInt8]()
        var t0 = Int(perf_counter_ns())
        write_values(vals, ts, blob)
        cw = min(cw, Int(perf_counter_ns()) - t0)
        cbytes = len(blob)
        var outv = List[Transform](capacity=n)
        var pos = 0
        var t1 = Int(perf_counter_ns())
        _ = read_values(outv, Transform.at(Vec3(0, 0, 0, 0)), ts, blob, pos)
        cr = min(cr, Int(perf_counter_ns()) - t1)
        keep(outv[n - 1].translation[0])
    t.add("schema batch write (" + String(cbytes // n) + " B/value)", n, "value", cw, n)
    t.add("schema batch read", n, "value", cr, n)

    var hw = Int.MAX
    var hr = Int.MAX
    for _ in range(REPS):
        var buf = List[Float32]()
        var t0 = Int(perf_counter_ns())
        for i in range(n):
            _hand_write(vals[i], buf)
        hw = min(hw, Int(perf_counter_ns()) - t0)
        var pos = 0
        var t1 = Int(perf_counter_ns())
        for _ in range(n):
            var v = _hand_read(buf, pos)
            keep(v.translation[0])
        hr = min(hr, Int(perf_counter_ns()) - t1)
    t.add("hand-written write (48 B/value)", n, "value", hw, n)
    t.add("hand-written read", n, "value", hr, n)


def main() raises:
    var t = BenchTable("Transform serialisation: reflection-driven schema vs hand-written")
    for n in [16, 1024, 65536]:
        _rows(t, n)
    t.print_report()
