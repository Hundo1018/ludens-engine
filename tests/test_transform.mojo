"""Transform hierarchy + propagation parity, across two storage backends.

A root→child→grandchild chain validates hand-computed world positions, then the
key parity check: `propagate_full` and `propagate_dirty` produce identical world
matrices both initially and after moving the root (where the dirty path rebuilds
only the moved subtree and reuses cached worlds elsewhere).
"""

from harness.runner import Suite
from ecs.world import World
from ecs.storage import StorageBackend
from ecs.sparse_backend import SparseSetBackend
from ecs.archetype import ArchetypeBackend
from ecs.entity import Entity
from ecs.transform import Transform, Parent
from ecs.hierarchy import Hierarchy
from ecs.transform_systems import propagate_full, propagate_dirty
from geometry.vec import Vec3
from geometry.mat import transform_point4


def build_scene[B: StorageBackend](mut w: World[B]) -> List[Entity]:
    # root at (10,0,0); child local (1,0,0) under root; grandchild local (0,2,0) under child
    var root = w.spawn()
    w.set(root, Transform.at(Vec3(10, 0, 0)))
    var child = w.spawn()
    w.set(child, Transform.at(Vec3(1, 0, 0)))
    w.set(child, Parent(root.id))
    var gc = w.spawn()
    w.set(gc, Transform.at(Vec3(0, 2, 0)))
    w.set(gc, Parent(child.id))
    var es = List[Entity]()
    es.append(root)
    es.append(child)
    es.append(gc)
    return es^


def world_origin[B: StorageBackend](w: World[B], e: Entity) -> Vec3:
    return transform_point4(w.get[Transform](e).world, Vec3(0, 0, 0))


def check_hierarchy[B: StorageBackend](mut s: Suite, tag: String):
    var w = World[B]()
    var es = build_scene(w)
    var h = Hierarchy.build(w)
    propagate_full(w, h)

    var rp = world_origin(w, es[0])
    s.almost(Float64(rp[0]), 10.0, tag + " root x")
    var cp = world_origin(w, es[1])
    s.almost(Float64(cp[0]), 11.0, tag + " child x")
    var gp = world_origin(w, es[2])
    s.almost(Float64(gp[0]), 11.0, tag + " gc x")
    s.almost(Float64(gp[1]), 2.0, tag + " gc y")

    var gt = w.get[Transform](es[2])
    s.check(not gt.local_dirty, tag + " gc local clean")
    s.check(not gt.world_dirty, tag + " gc world clean")


def compare_worlds[B: StorageBackend, C: StorageBackend](
    mut s: Suite,
    label: String,
    wf: World[B],
    ef: List[Entity],
    wd: World[C],
    ed: List[Entity],
):
    for i in range(len(ef)):
        var a = wf.get[Transform](ef[i]).world
        var b = wd.get[Transform](ed[i]).world
        comptime for r in range(4):
            comptime for c in range(4):
                s.almost(
                    Float64(a.get(r, c)), Float64(b.get(r, c)), label + " world m", 1e-4
                )


def check_parity[B: StorageBackend](mut s: Suite, tag: String):
    var wf = World[B]()
    var ef = build_scene(wf)
    var wd = World[B]()
    var ed = build_scene(wd)

    var hf = Hierarchy.build(wf)
    propagate_full(wf, hf)
    var hd = Hierarchy.build(wd)
    propagate_dirty(wd, hd)
    compare_worlds(s, tag + " initial", wf, ef, wd, ed)

    # move the root in both worlds; dirty path must rebuild only the subtree
    var rf = wf.get[Transform](ef[0])
    wf.set(ef[0], rf.with_translation(Vec3(5, 7, -1)))
    var rd = wd.get[Transform](ed[0])
    wd.set(ed[0], rd.with_translation(Vec3(5, 7, -1)))

    var hf2 = Hierarchy.build(wf)
    propagate_full(wf, hf2)
    var hd2 = Hierarchy.build(wd)
    propagate_dirty(wd, hd2)
    compare_worlds(s, tag + " after move", wf, ef, wd, ed)

    # grandchild world should have followed the root move: x = 5 + 1 + 0 = 6, y = 7 + 2 = 9
    var gp = world_origin(wd, ed[2])
    s.almost(Float64(gp[0]), 6.0, tag + " moved gc x", 1e-4)
    s.almost(Float64(gp[1]), 9.0, tag + " moved gc y", 1e-4)


def main() raises:
    var s = Suite("transform")
    check_hierarchy[SparseSetBackend[Transform, Parent]](s, "sparse")
    check_hierarchy[ArchetypeBackend[Transform, Parent]](s, "archetype")
    check_parity[SparseSetBackend[Transform, Parent]](s, "sparse")
    check_parity[ArchetypeBackend[Transform, Parent]](s, "archetype")
    s.finish()
