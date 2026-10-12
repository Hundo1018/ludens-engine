"""Python binding cost (ROADMAP 17.21): the `ludens` package (ctypes over the
C-ABI) vs native `EmbedWorld`, on the scene of bench_capi.

Rows: a 120-tick step (after 20 warm-up ticks) where a PRE system reads and
sets every 10th box's velocity (Python function vs Mojo loop; the label says
whether the hashes match), per-body state reads, the batch pose read into a
caller buffer, `World.bodies()` with its per-body Python objects, and the
cost of one no-op Python system callback.

Run: pixi run mojo run -I build benchmarks/bench_python.mojo
(uses the repo's python/ package with a freshly built library via
LUDENS_LIBRARY; the installed-wheel path is tested by test_python_binding).
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


def main() raises:
    var t = BenchTable("Python bindings (17.21): ludens package (ctypes over libludens.so) vs native EmbedWorld")
    var sp = Python.import_module("subprocess")
    var os = Python.import_module("os")
    var tmp = String(Python.import_module("tempfile").mkdtemp(prefix="ludens_bench_py_"))
    var lib = tmp + "/libludens.so"
    var r = sp.run(Python.list("mojo", "build", "--emit", "shared-lib", "-I", "build", "-o", lib, "embed/capi.mojo"), capture_output=True, text=True)
    if Int(py=r.returncode) != 0:
        raise Error(String(r.stderr))
    var env = os.environ.copy()
    env["LUDENS_LIBRARY"] = lib
    env["PYTHONPATH"] = "python"

    for n in [100, 1000]:
        r = sp.run(Python.list("python3", "benchmarks/python/bench_client.py", String(n), String(TICKS), String(WARM)), capture_output=True, text=True, env=env)
        if Int(py=r.returncode) != 0:
            raise Error(String(r.stderr))
        var rows = List[List[String]]()
        for line in String(r.stdout).split("\n"):
            if String(line).startswith("row|"):
                var f = List[String]()
                for p in String(line).split("|"):
                    f.append(String(p))
                rows.append(f^)

        var bodies = List[Int64]()
        var w = scene(n, bodies)
        for _ in range(WARM):
            push(w, bodies)
            w.physics_tick()
        var t0 = now()
        for _ in range(TICKS):
            push(w, bodies)
            w.physics_tick()
        var ns = now() - t0
        var same = String(w.hash()) == rows[0][6]
        t.add("native: step with a Mojo loop pushing every 10th box (hash == Python: " + String(same) + ")", n, "tick", ns, TICKS)
        for ref f in rows:
            t.add(f[1], n, f[3], Int(f[4]), Int(f[5]))
        var calls = 0
        var acc = Real(0)
        t0 = now()
        for _ in range(200000 // n):
            for b in bodies:
                acc += w.state(b).pos[1]
                calls += 1
        t.add("native: EmbedWorld.state per body", n, "call", now() - t0, calls)
        if acc == 12345.678:
            print("")
    _ = Python.import_module("shutil").rmtree(tmp)
    t.print_report()
