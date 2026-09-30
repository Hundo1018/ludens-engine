"""Host that never touches std.random itself: load a plugin that calls
random_ui64, unload it, exit.

Prediction written before the run: the plugin registers the destroy function
of the stdlib "random_state" global; after dlclose that code is unmapped and
the exit-time KGEN_CompilerRT_DestroyGlobals crashes (exit 139). With the
plugin kept loaded (argv[2] == "keep") the host exits 0.
"""
from std.ffi import OwnedDLHandle, RTLD, _DLHandle
from std.sys import argv

def main() raises:
    var d = String(argv()[1])
    var keep = len(argv()) > 2 and String(argv()[2]) == "keep"
    if keep:
        var pin = _DLHandle(d + "/libplugin_rand.so", RTLD.NOW | RTLD.LOCAL)
        _ = pin
    var h = OwnedDLHandle(d + "/libplugin_rand.so", RTLD.NOW | RTLD.LOCAL)
    print("roll=", h.get_function[Int]("roll")(), " keep=", keep)
    _ = h^
    print("exiting")
