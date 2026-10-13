# tier: component  (override: compiles generated ECS programs as subprocesses; they use ecs only)
"""Compile-time guards on component packs (ROADMAP 17.77).

Every backend calls `ecs.storage.check_pack` in its constructor. This test
writes three small programs to a temporary directory and builds them with
`mojo build -I build`:

  1. control: two components with distinct IDs -- builds;
  2. two components sharing ID 0 -- fails with "duplicate component ID";
  3. 64 components (IDs 0..63) -- fails with "at most 63 types" (slot
     bitmasks are `Int`).
"""

from std.python import Python, PythonObject
from harness.runner import Suite


def _program(n: Int, dup: Bool) -> String:
    var src = String("from ecs.world import World\nfrom ecs.archetype import ArchetypeBackend\nfrom ecs.component import ComponentType\n\n")
    for i in range(n):
        var id = 0 if dup else i
        src += "@fieldwise_init\nstruct T" + String(i) + "(ComponentType):\n    comptime ID: Int = " + String(id) + "\n    var v: Int\n\n"
    src += "def main():\n    var w = World[ArchetypeBackend["
    for i in range(n):
        if i > 0:
            src += ", "
        src += "T" + String(i)
    src += "]]()\n    _ = w.spawn()\n"
    return src^


def _build(sp: PythonObject, tmp: String, name: String, src: String) raises -> PythonObject:
    var path = tmp + "/" + name + ".mojo"
    var f = Python.import_module("builtins").open(path, "w")
    _ = f.write(src)
    _ = f.close()
    return sp.run(Python.list("mojo", "build", "-I", "build", path, "-o", tmp + "/" + name), capture_output=True, text=True)


def main() raises:
    var s = Suite("ecs_pack_guard")
    var sp = Python.import_module("subprocess")
    var tmp = String(Python.import_module("tempfile").mkdtemp())
    var ok = _build(sp, tmp, "control", _program(2, False))
    s.check(Int(py=ok.returncode) == 0, "control: a pack with distinct IDs builds")
    var dup = _build(sp, tmp, "dup", _program(2, True))
    var dup_err = String(dup.stderr) + String(dup.stdout)
    s.check(Int(py=dup.returncode) != 0 and "duplicate component ID" in dup_err, "duplicate ID: compile error naming it")
    var big = _build(sp, tmp, "big", _program(64, False))
    var big_err = String(big.stderr) + String(big.stdout)
    s.check(Int(py=big.returncode) != 0 and "at most 63 types" in big_err, "64 types: compile error naming the limit")
    _ = Python.import_module("shutil").rmtree(tmp)
    s.finish()
