"""Compile-time rule for hot-reloadable state (H2): no field may hold a
pointer or a string view, because after the old .so is unloaded such a field
may point into unmapped static data (README finding 2).

    assert_no_static_refs[EngineState]()   # in any function that is compiled

A violation fails the build with
    constraint failed: state field holds a pointer or string view: <field>

Scope, measured in probes/probe_nostatic.mojo: the DIRECT fields of `T` are
checked by type name (`reflect[FT].base_name()`). Heap containers (`List`,
`SparseSet`, ...) are allowed, since all modules share one allocator (finding 3),
and their type parameters are not inspected: `SparseSet[StaticString]` passes.
"""

comptime FORBIDDEN: List[StaticString] = [
    "StringSpan",  # StaticString, StringSlice
    "StringSlice",
    "Span",
    "Pointer",
    "UnsafePointer",
    "OpaquePointer",
]


def _forbidden(name: StaticString) -> Bool:
    for f in materialize[FORBIDDEN]():
        if f == name:
            return True
    return False


def assert_no_static_refs[T: AnyType]():
    comptime names = reflect[T].field_names()
    comptime for i in range(reflect[T].field_count()):
        comptime FT = reflect[T].field_at[i].T
        comptime assert not _forbidden(
            reflect[FT].base_name()
        ), "state field holds a pointer or string view: " + names[i]
