"""The crash import (issue #147, docs/telemetry.md): where the packed crash context lies in wasm memory.

    os_crash_arm(ptr, len) -> 0     the host keeps the address; on a trap it copies `len` bytes from `ptr` without calling
                                    into the module and writes the crash report (shell/web/crash_host.mjs). len 0 disarms.

Call it after every `CrashReporter.arm` (platform/crash_report.mojo): the context moves when it is packed again."""
from std.ffi import external_call
from platform.crash_report import CrashReporter


def os_crash_arm(ptr: UInt64, length: UInt64) -> Int32:
    return external_call["os_crash_arm", Int32](ptr, length)


def arm_web(mut rep: CrashReporter, tick: Int, session_ms: Int) -> Int:
    """`rep.arm` and tell the host where the context now is (or disarm it when the player has not opted in)."""
    var n = rep.arm(tick, session_ms)
    _ = os_crash_arm(rep.context_ptr(), UInt64(n))
    return n
