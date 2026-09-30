"""Probe for nostatic.assert_no_static_refs.

    mojo run -I build -I experiments/hot_reload/native experiments/hot_reload/native/probes/probe_nostatic.mojo
        -> prints "ok", and "gap: SparseSet[StaticString] passes"
    same with -D BAD=1
        -> build fails: "constraint failed: state field holds a pointer or string view: label"
"""
from std.sys import is_defined
from ecs.sparse_set import SparseSet
from nostatic import assert_no_static_refs


struct Good(Movable):
    var a: Int
    var label_id: Int
    var set: SparseSet[Float32]


struct Bad(Movable):
    var a: Int
    var label: StaticString


struct Gap(Movable):
    var labels: SparseSet[StaticString]


def main():
    assert_no_static_refs[Good]()
    comptime if is_defined["BAD"]():
        assert_no_static_refs[Bad]()
    print("ok")
    assert_no_static_refs[Gap]()
    print("gap: SparseSet[StaticString] passes")
