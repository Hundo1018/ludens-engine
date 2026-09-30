"""Fault guard for H1: run one call into an engine .so and turn a SIGSEGV /
SIGBUS / SIGFPE / SIGILL / SIGABRT in it into a return value, the way cr.h
does, so the host can roll back instead of dying.

Mechanism, measured in probes/probe_sigjmp.mojo:
  * `__sigsetjmp` / `siglongjmp` through `external_call` work from Mojo.
  * Mojo 1.1 has no global variables, so the signal handler cannot reach a
    jmp_buf through one. The jmp_buf lives on a page mapped at a fixed
    address (MAP_FIXED_NOREPLACE) that the handler knows as a constant.
  * A local modified between sigsetjmp and the fault is indeterminate
    afterwards (the probe's counter read 0 again), as in C. `guarded_*` keep
    nothing live across the call; the state is in the host's heap block.

The page layout: [0, 512) jmp_buf, [512] armed flag, [520] last signal.
When the flag is 0 (no guarded call running) the handler restores the
default action and returns, so the fault repeats and kills the process as it
would without the guard.

Not handled: a fault while the engine holds a lock (e.g. inside malloc)
leaves that lock held; the next call that needs it deadlocks.
"""

from std.ffi import external_call
from std.memory import alloc, Layout
from hotswap import Engine

comptime GUARD_PAGE = 0x7E5A00000000
comptime _ARMED = GUARD_PAGE + 512
comptime _LAST = GUARD_PAGE + 520
comptime _SIGNALS: List[Int32] = [4, 6, 7, 8, 11]  # ILL, ABRT, BUS, FPE, SEGV
comptime _WordPtr = type_of(alloc[Int](Layout[Int](count=1)).unsafe_leak())


def _word(addr: Int) -> _WordPtr:
    return _WordPtr(unsafe_from_address=addr)


def _on_fault(sig: Int32) abi("C"):
    if _word(_ARMED)[] == 0:
        # SIG_DFL: let it crash. `bsd_signal` is glibc's `signal` under another
        # name; one symbol cannot be declared with two signatures.
        _ = external_call["bsd_signal", Int](sig, 0)
        return
    _word(_ARMED)[] = 0
    _word(_LAST)[] = Int(sig)
    external_call["siglongjmp", NoneType](GUARD_PAGE, Int32(1))


def guard_install() raises:
    """Map the jmp_buf page and install the handler. Call once per process."""
    var got = external_call["mmap", Int](
        GUARD_PAGE, 4096, Int32(3), Int32(0x02 | 0x20 | 0x100000), Int32(-1), 0
    )
    if got != GUARD_PAGE:
        raise Error("guard: fixed page " + hex(GUARD_PAGE) + " not available")
    _word(_ARMED)[] = 0
    for sig in materialize[_SIGNALS]():
        _ = external_call["signal", Int](sig, _on_fault)


@no_inline
def guarded_update(eng: Engine, s: Int) -> Int:
    """`eng.update(s)`: 0, the signal that stopped it, or -1 if it raised."""
    if external_call["__sigsetjmp", Int32](GUARD_PAGE, Int32(1)) != 0:
        return _word(_LAST)[]
    _word(_ARMED)[] = 1
    try:
        eng.update(s)
    except:
        _word(_ARMED)[] = 0
        return -1
    _word(_ARMED)[] = 0
    return 0


@no_inline
def guarded_load(eng: Engine, s: Int, buf: Int) -> Int:
    """`eng.load(s, buf)`: 0 on success, the signal that stopped it (> 0),
    -1 if it raised, or -(10 + code) if engine_load returned `code` != 1."""
    if external_call["__sigsetjmp", Int32](GUARD_PAGE, Int32(1)) != 0:
        return _word(_LAST)[]
    _word(_ARMED)[] = 1
    var code: Int
    try:
        code = eng.load(s, buf)
    except:
        _word(_ARMED)[] = 0
        return -1
    _word(_ARMED)[] = 0
    return 0 if code == 1 else -(10 + code)
