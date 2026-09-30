"""Probe (H4): does valgrind see the end of a block from Mojo's `alloc`?

Writes 8 bytes just past a 40-byte block, once from `alloc` (what the host's
`block()` used until H4) and once from libc `malloc`; then a read-modify-write
past a malloc block 3 times. Run under valgrind:

    mojo build --target-cpu x86-64-v3 probes/probe_alloc_bounds.mojo -o build/probe_alloc_bounds
    valgrind build/probe_alloc_bounds
"""
from std.ffi import external_call
from std.memory import alloc, Layout

comptime WordPtr = type_of(alloc[Int](Layout[Int](count=1)).unsafe_leak())


def main():
    var a = Int(alloc[UInt8](Layout[UInt8](count=40)).unsafe_leak())
    print("alloc  block at", hex(a), flush=True)
    WordPtr(unsafe_from_address=a + 40)[] = 7
    print("alloc  wrote past the end", flush=True)
    var m = external_call["malloc", Int](40)
    print("malloc block at", hex(m), flush=True)
    WordPtr(unsafe_from_address=m + 40)[] = 7
    print("malloc wrote past the end", flush=True)
    # read-modify-write past the end, 3 times (what `s.extra += 1` compiles to:
    # one `incq`). Expected under valgrind: 6 errors (load + store) in 1 context.
    var r = external_call["malloc", Int](40)
    for _ in range(3):
        WordPtr(unsafe_from_address=r + 40)[] += 1
    print("malloc rmw past the end x3", flush=True)
