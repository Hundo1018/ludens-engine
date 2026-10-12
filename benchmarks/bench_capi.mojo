"""C-ABI boundary cost (ROADMAP 12.1): the same work driven by a C host
through build/libludens.so (`benchmarks/capi/bench_host.c`) and natively on
`EmbedWorld`.

Scene: n boxes in two-box stacks on a floor; a PRE system reads the state of
every 10th box and sets its velocity (sideways, flipping each second) every
tick. Rows: a 120-tick step (after 20 untimed warm-up ticks) with that system (C: a C callback calling back
into the library; native: a Mojo loop), the state of every body read one at
a time, all poses in one batch call, save and load. The step row label says
whether the C and native world hashes match after the 140 ticks.

Needs gcc. Run: pixi run mojo run -I build benchmarks/bench_capi.mojo
"""

from std.python import Python, PythonObject
from harness.bench import BenchTable, now
from geometry.vec import Real, Vec3
from embed.world import EmbedWorld

comptime TICKS = 120
comptime WARM = 20


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def scene(n: Int, mut bodies: List[Int64]) raises -> EmbedWorld:
    var w = EmbedWorld(1.0 / 60.0, _v(0, -9.8, 0))
    var side = 1
    while side * side * 2 < n:
        side += 1
    var L = Real(side) * 2
    _ = w.add_box(_v(L / 2, -0.5, L / 2), _v(L / 2 + 1, 0.5, L / 2 + 1), 0, True)
    var made = 0
    for gx in range(side):
        for gz in range(side):
            for k in range(2):
                if made < n:
                    bodies.append(w.add_box(_v(Real(gx) * 2 + 1, 0.25 + 0.51 * Real(k), Real(gz) * 2 + 1), _v(0.25, 0.25, 0.25), 1, False))
                    made += 1
    return w^


def push(mut w: EmbedWorld, bodies: List[Int64]) raises:
    var vx: Real = 1 if (w.tick // 60) % 2 == 0 else -1
    var i = 0
    while i < len(bodies):
        var st = w.state(bodies[i])
        w.set_velocity(bodies[i], _v(vx, st.vel[1], 0), st.omega)
        i += 10


def _sh(sp: PythonObject, cmd: PythonObject) raises -> String:
    var r = sp.run(cmd, capture_output=True, text=True)
    if Int(py=r.returncode) != 0:
        raise Error("command failed: " + String(cmd) + "\n" + String(r.stderr))
    return String(r.stdout)


def main() raises:
    var t = BenchTable("C-ABI boundary (12.1): C host through libludens.so vs native EmbedWorld")
    var sp = Python.import_module("subprocess")
    var bi = Python.import_module("builtins")
    var tmp = String(Python.import_module("tempfile").mkdtemp(prefix="ludens_bench_capi_"))
    var lib = tmp + "/libludens.so"
    var host = tmp + "/host"
    _ = _sh(sp, Python.list("mojo", "build", "--emit", "shared-lib", "-I", "build", "-o", lib, "embed/capi.mojo"))
    _ = _sh(sp, Python.list("gcc", "-O2", "-std=c99", "-Iembed", "benchmarks/capi/bench_host.c", "-L" + tmp, "-lludens", "-Wl,-rpath," + tmp, "-o", host))

    for n in [100, 1000]:
        var out = _sh(sp, Python.list(host, String(n), String(TICKS)))
        var c_hash = String()
        var c_rows = List[List[String]]()
        for line in out.split("\n"):
            if not String(line).startswith("row|"):
                continue
            var f = List[String]()
            for p in String(line).split("|"):
                f.append(String(p))
            if c_hash.byte_length() == 0:
                c_hash = String(bi.str(bi.int(f[6], 16)))
            c_rows.append(f^)

        var bodies = List[Int64]()
        var w = scene(n, bodies)
        for _ in range(WARM):
            push(w, bodies)
            w.physics_tick()
        var t0 = now()
        for _ in range(TICKS):
            push(w, bodies)
            w.physics_tick()
        var step_ns = now() - t0
        var same = String(w.hash()) == c_hash
        t.add("native: step with a Mojo loop pushing every 10th box (hash == C host: " + String(same) + ")", n, "tick", step_ns, TICKS)
        t.add(c_rows[0][1], n, c_rows[0][3], Int(c_rows[0][4]), Int(c_rows[0][5]))

        var calls = 0
        var acc = Real(0)
        t0 = now()
        for _ in range(1000000 // n):
            for b in bodies:
                acc += w.state(b).pos[1]
                calls += 1
        var st_ns = now() - t0
        t.add("native: EmbedWorld.state per body", n, "call", st_ns, calls)
        t.add(c_rows[1][1], n, c_rows[1][3], Int(c_rows[1][4]), Int(c_rows[1][5]))
        t.add(c_rows[2][1], n, c_rows[2][3], Int(c_rows[2][4]), Int(c_rows[2][5]))

        var blob = w.save()
        t0 = now()
        for _ in range(20):
            blob = w.save()
        var save_ns = now() - t0
        t0 = now()
        for _ in range(20):
            w.load(blob)
        var load_ns = now() - t0
        t.add("native: EmbedWorld.save (" + String(len(blob)) + " B)", n, "save", save_ns, 20)
        t.add(c_rows[3][1], n, c_rows[3][3], Int(c_rows[3][4]), Int(c_rows[3][5]))
        t.add("native: EmbedWorld.load", n, "load", load_ns, 20)
        t.add(c_rows[4][1], n, c_rows[4][3], Int(c_rows[4][4]), Int(c_rows[4][5]))
        if acc == 12345.678:
            print("")
    _ = Python.import_module("shutil").rmtree(tmp)
    t.print_report()
