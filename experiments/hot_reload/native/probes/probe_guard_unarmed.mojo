"""Probe (H1): a fault outside a guarded call must still kill the process.

    build/probe_guard_unarmed ; echo $?   -> 139 (SIGSEGV), after "before fault"
"""
from std.memory import alloc, Layout
from guard import guard_install

comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())


def main() raises:
    guard_install()
    print("before fault", flush=True)
    BytePtr(unsafe_from_address=8)[] = 1
    print("not reached: the guard swallowed an unguarded fault")
