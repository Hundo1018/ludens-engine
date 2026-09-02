# Probe: alloc free function + MutableAnyOrigin erased pointer slots.
from std.memory import UnsafePointer, alloc


@fieldwise_init
struct Foo(Copyable, Movable):
    var a: Int
    var b: Int


def main() raises:
    var p = alloc[Foo](1)
    p.unsafe_write(Foo(7, 8))
    print("foo =", p[].a, p[].b)

    # Erase to an untracked-origin opaque pointer (suitable as a struct field).
    var op = p.unsafe_bitcast[NoneType]()
    var q = op.unsafe_bitcast[Foo]()
    print("via opaque =", q[].a, q[].b)

    p.unsafe_deinit_pointee()
    p.unsafe_free()
    print("ptr probe PASS")
