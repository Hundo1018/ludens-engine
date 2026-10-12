# tier: integration  (override: drives the f32 and f64 builds as subprocesses; the probe it runs exercises physics only)
"""The f64 world scalar (ROADMAP 17.8): the whole engine builds with
`WorldType = float64`, and the f64 and f32 builds agree in a small world.

1. `scripts/build_f64.sh` precompiles every package into build64/ (about a
   minute) -- the parameterisation is real, not just declared.
2. `benchmarks/large_world/probe.mojo` under build64/ reports float64, and a
   0.5 m/s body 1e7 m out travels 0.5 m to within 1 um (f32 cannot move it
   at all there, see test_large_world).
3. Small world: f32 and f64 builds give the same slow-mover travel (< 10 um)
   and a settling stack's top box within 2 mm after 4 s (stacking contact
   resolution amplifies rounding differences; 0.9 mm measured).
"""

from std.python import Python, PythonObject
from harness.runner import Suite


def probe(sp: PythonObject, build: String, mode: String, d: String) raises -> List[String]:
    var r = sp.run(Python.list("mojo", "run", "-I", build, "benchmarks/large_world/probe.mojo", mode, d), capture_output=True, text=True)
    if Int(py=r.returncode) != 0:
        raise Error("probe failed (" + build + "): " + String(r.stderr))
    var lines = String(r.stdout).strip().split("\n")
    var out = List[String]()
    for f in String(lines[len(lines) - 1]).split(" "):
        out.append(String(f))
    return out^


def main() raises:
    var s = Suite("world_f64")
    var sp = Python.import_module("subprocess")
    var r = sp.run(Python.list("bash", "scripts/build_f64.sh"), capture_output=True, text=True)
    s.check(Int(py=r.returncode) == 0, "every package precompiles with WorldType = float64")
    if Int(py=r.returncode) != 0:
        print(String(r.stdout), String(r.stderr))
        s.finish()
        return
    var far = probe(sp, "build64", "slow", "10000000")
    s.check(far[0] == "float64", "build64 runs with a float64 world scalar")
    s.check(Float64(far[1]) < 1e-6, "f64: 0.5 m/s body at 1e7 m travels 0.5 m (error " + far[1] + " m)")
    var s32 = probe(sp, "build", "slow", "0")
    var s64 = probe(sp, "build64", "slow", "0")
    s.check(s32[0] == "float32" and Float64(s32[1]) < 1e-5 and Float64(s64[1]) < 1e-5, "small world: both builds move the slow body 0.5 m (f32 " + s32[1] + ", f64 " + s64[1] + ")")
    var k32 = probe(sp, "build", "stack", "0")
    var k64 = probe(sp, "build64", "stack", "0")
    var dp = Float64(0)
    for i in range(1, 4):
        dp = max(dp, abs(Float64(k32[i]) - Float64(k64[i])))
    print("  settling stack, top box |f32 - f64|:", dp, "m")
    s.check(dp < 2e-3, "small world: f32 and f64 stacks agree within 2 mm")
    s.finish()
