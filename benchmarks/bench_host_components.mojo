"""ROADMAP 17.78: host-defined (byte blob) vs compile-time components.

N entities; a `Health` f64 written then read for each, on a sparse-set
`World` (compile-time component) and through `HostComponents` (registered
at run time, f64 at offset 0). Nanoseconds per entity for write and read,
and for a full query of the holders.
"""

from std.time import perf_counter_ns
from std.benchmark import keep
from ecs.world import World
from ecs.sparse_backend import SparseSetBackend
from ecs.component import ComponentType
from ecs.entity import Entity
from ecs.host_components import HostComponents


@fieldwise_init
struct Health(ComponentType):
    comptime ID: Int = 0
    var hp: Float64


def main() raises:
    print("### Host-defined vs compile-time components (17.78)\n")
    print("| N | kind | write ns | read ns | query ns per entity |")
    print("|---:|---|---:|---:|---:|")
    for n in [1000, 100000]:
        var w = World[SparseSetBackend[Health]]()
        var hc = HostComponents()
        var hid = hc.register("Health", 8)
        var es = List[Entity]()
        for _ in range(n):
            es.append(w.spawn())
        var t0 = Int(perf_counter_ns())
        for i in range(n):
            w.set(es[i], Health(Float64(i)))
        var t1 = Int(perf_counter_ns())
        var acc = Float64(0)
        for i in range(n):
            acc += w.get[Health](es[i]).hp
        var t2 = Int(perf_counter_ns())
        var q = w.query1[Health]()
        var t3 = Int(perf_counter_ns())
        for i in range(n):
            hc.set_f64(es[i], hid, 0, Float64(i))
        var t4 = Int(perf_counter_ns())
        for i in range(n):
            acc += hc.get_f64(es[i], hid, 0)
        var t5 = Int(perf_counter_ns())
        var q2 = hc.matching(hid)
        var t6 = Int(perf_counter_ns())
        keep(acc)
        keep(len(q) + len(q2))
        print("|", n, "| compile-time |", (t1 - t0) // n, "|", (t2 - t1) // n, "|", (t3 - t2) // n, "|")
        print("|", n, "| host blob |", (t4 - t3) // n, "|", (t5 - t4) // n, "|", (t6 - t5) // n, "|")
    print("")
