"""Probe (H1): can pure Mojo recover from a SIGSEGV with sigsetjmp/siglongjmp?

Mojo 1.1 has no global variables, so the handler cannot find a jmp_buf
through one. The jmp_buf lives on a page mapped at a fixed address
(MAP_FIXED_NOREPLACE) that the handler knows as a compile-time constant.

    mojo build probes/probe_sigjmp.mojo -o build/probe_sigjmp && build/probe_sigjmp
"""
from std.ffi import external_call
from std.memory import alloc, Layout

comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())
comptime GUARD_PAGE = 0x7E5A00000000
comptime PROT_RW = 3
comptime MAP_PRIVATE_ANON_FIXED_NOREPLACE = 0x02 | 0x20 | 0x100000


def on_segv(sig: Int32) abi("C"):
    external_call["siglongjmp", NoneType](GUARD_PAGE, Int32(1))


def main() raises:
    var got = external_call["mmap", Int](GUARD_PAGE, 4096, Int32(PROT_RW), Int32(MAP_PRIVATE_ANON_FIXED_NOREPLACE), Int32(-1), 0)
    print("mmap", hex(got), "wanted", hex(GUARD_PAGE))
    if got != GUARD_PAGE:
        raise Error("fixed page not available")
    _ = external_call["signal", Int](Int32(11), on_segv)
    var counter = 0
    for round in range(3):
        var r = external_call["__sigsetjmp", Int32](GUARD_PAGE, Int32(1))
        print("round", round, "sigsetjmp returned", r, "counter", counter)
        if r == 0:
            counter += 1
            var p = BytePtr(unsafe_from_address=8)
            p[] = 1
            print("not reached")
        else:
            print("recovered in round", round)
    print("done counter", counter)
