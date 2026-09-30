"""Example 23 — an inspector built on reflection (ROADMAP 17.11).

Nothing below lists a field by hand. `TypeRegistry.register[T]()` reads the
field table off the type at compile time (`reflect[T]`), and the inspector
works from names and addresses only -- the shape a property panel, a network
replicator or a script binding has. It prints every leaf of `Transform` and
`SolverConfig`, edits two of them by name, saves a batch of Transforms, and
loads it back through the name-matching reader.

Run:

    pixi run mojo run -I build examples/23_reflection_inspector.mojo
"""

from geometry.vec import Real, Vec3
from ecs.transform import Transform
from ecs.schema import TypeRegistry, address_of, schema_of, write_values, read_values
from physics.solver_config import SolverConfig


def show(reg: TypeRegistry, addr: Int, type_name: String) raises:
    var t = reg.find(type_name)
    print(type_name, "(", reg.schemas[t].size, "bytes )")
    for i in range(len(reg.schemas[t].fields)):
        ref f = reg.schemas[t].fields[i]
        var line = "  " + f.name + " : " + f.type_name + " @" + String(f.offset)
        try:
            line += " = " + String(reg.get_f64(addr, type_name, f.name))
        except:
            line += " (not a scalar)"
        print(line)


def main() raises:
    var reg = TypeRegistry()
    _ = reg.register[Transform]()
    _ = reg.register[SolverConfig]()

    var tr = Transform.at(Vec3(1, 2, 3, 0))
    var cfg = SolverConfig()
    show(reg, address_of(tr), "Transform")
    show(reg, address_of(cfg), "SolverConfig")

    reg.set_f64(address_of(tr), "Transform", "rotation.w", 0.5)
    reg.set_f64(address_of(cfg), "SolverConfig", "substeps", 8)
    print("edited by name: rotation.w =", tr.rotation.w, " substeps =", cfg.substeps)

    var batch = List[Transform]()
    for i in range(4):
        batch.append(Transform.at(Vec3(Real(i), 0, 0, 0)))
    var blob = List[UInt8]()
    var ts = schema_of[Transform]()
    write_values(batch, ts, blob)
    var back = List[Transform]()
    var pos = 0
    var rep = read_values(back, Transform.at(Vec3(0, 0, 0, 0)), ts, blob, pos)
    print("saved", len(batch), "Transforms in", len(blob), "bytes; restored", len(back), "with", rep.restored, "fields matched by name")
