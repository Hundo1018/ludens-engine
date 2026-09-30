"""Mojo host: a stdlib `_Global` across a module swap.

Loads libglobal_v1.so, calls `bump` twice (+1 each), unloads it, loads
libglobal_v100.so, calls `bump` once (+100), exits.

Predictions, written before the first run:
- the counter reads 1, 2, 102: the named global lives in the shared
  CompilerRT, not in either module;
- at exit KGEN_CompilerRT_DestroyGlobals calls the destroy function that v1
  registered, whose code is unmapped: SIGSEGV. With `keep` (v1 pinned by a
  second, never-closed handle) the host exits 0.

Usage: host_swap_global <dir with the two .so> [keep]
"""
from std.ffi import OwnedDLHandle, RTLD, _DLHandle
from std.sys import argv


def main() raises:
    var d = String(argv()[1])
    var keep = len(argv()) > 2 and String(argv()[2]) == "keep"
    if keep:
        var pin = _DLHandle(d + "/libglobal_v1.so", RTLD.NOW | RTLD.LOCAL)
        _ = pin
    var v1 = OwnedDLHandle(d + "/libglobal_v1.so", RTLD.NOW | RTLD.LOCAL)
    var r1 = v1.get_function[Int]("bump")()
    var r2 = v1.get_function[Int]("bump")()
    _ = v1^  # dlclose
    var v100 = OwnedDLHandle(d + "/libglobal_v100.so", RTLD.NOW | RTLD.LOCAL)
    var r3 = v100.get_function[Int]("bump")()
    print("v1:", r1, r2, " v100:", r3, " survived=", r3 == 102, " keep=", keep)
