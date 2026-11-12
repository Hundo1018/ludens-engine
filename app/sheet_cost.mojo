"""What an event sheet costs per tick against the same logic written as Mojo code (ludens-engine #24).

N events, each `when tick_mod k` + `when var x >= 0` + `do add x 1`. Two shapes: every event shares one of 16 variables,
or every event has its own variable. The Mojo version keeps the same counters in a list and does the same tests.
Both run TICKS ticks on an empty world; the sums of the variables must agree. Prints one markdown table row per case.

Native: `pixi run -e wasm sheet-cost`."""
from embed.world import EmbedWorld
from game.eventsheet import Sheet
from geometry.vec import Vec3
from std.time import perf_counter_ns

comptime TICKS = 200


def sheet_text(n: Int, vars: Int) -> String:
    var s = String()
    for i in range(n):
        var v = "v" + String(i % vars)
        s += "event " + String(i + 1) + "\n  when tick_mod " + String(i % 7 + 1) + "\n  when var " + v + " >= 0\n  do add " + v + " 1\n"
    return s


def run_sheet(n: Int, vars: Int) raises -> Tuple[Float64, Int, Float64]:
    """(microseconds per tick, sum of the variables, parse milliseconds)"""
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    var text = sheet_text(n, vars)
    var p0 = perf_counter_ns()
    var sheet = Sheet.parse(text)
    var p1 = perf_counter_ns()
    var t0 = perf_counter_ns()
    for _ in range(TICKS):
        sheet.step(w)
    var t1 = perf_counter_ns()
    var total = 0
    for i in range(vars):
        total += sheet.get("v" + String(i))
    return (Float64(t1 - t0) / 1000.0 / Float64(TICKS), total, Float64(p1 - p0) / 1.0e6)


def run_code(n: Int, vars: Int) -> Tuple[Float64, Int]:
    var counters = List[Int](length=vars, fill=0)
    var mods = List[Int](capacity=n)
    var which = List[Int](capacity=n)
    for i in range(n):
        mods.append(i % 7 + 1)
        which.append(i % vars)
    var t0 = perf_counter_ns()
    for tick in range(TICKS):
        for i in range(n):
            if tick % mods[i] == 0 and counters[which[i]] >= 0:
                counters[which[i]] += 1
    var t1 = perf_counter_ns()
    var total = 0
    for i in range(vars):
        total += counters[i]
    return (Float64(t1 - t0) / 1000.0 / Float64(TICKS), total)


def main() raises:
    print("| events | variables | sheet µs / tick | Mojo µs / tick | ratio | sheet ns / event | parse ms | same result |")
    print("|---:|---:|---:|---:|---:|---:|---:|:--|")
    for n in [100, 1000, 10000]:
        for own in [False, True]:
            var vars = n if own else 16
            var a = run_sheet(n, vars)
            var b = run_code(n, vars)
            var ratio = a[0] / b[0] if b[0] > 0.0 else 0.0
            print("|", n, "|", vars, "|", a[0], "|", b[0], "|", ratio, "|", a[0] * 1000.0 / Float64(n), "|", a[2], "|", "yes" if a[1] == b[1] else "NO", "|")
