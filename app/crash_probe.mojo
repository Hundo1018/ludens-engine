"""A module for tests/test_crash.mjs (issue #147): arm a crash context, trap on purpose, and on the next launch read the
report the host saved (through OsCloudSave, the real os_file_* imports) and send it over a MemoryTransport. Built with
DWARF line tables so scripts/wasm_sourcemap.py can map the trap back to the line marked CRASH-LINE below."""
from std.memory import alloc
from os_cloud_save import OsCloudSave
from os_crash import arm_web
from platform.crash_report import CrashReporter, CrashUpload
from platform.telemetry import Telemetry, install_id_from
from platform.transport_memory import MemoryPipe, MemoryTransport
from platform.transport import poll_bytes


struct Probe(Movable):
    var tel: Telemetry
    var rep: CrashReporter
    var save: OsCloudSave
    var up: CrashUpload
    var game: MemoryTransport
    var collector: MemoryTransport
    var sent: List[UInt8]

    def __init__(out self):
        self.tel = Telemetry("crash-probe 1", 99)
        self.rep = CrashReporter("crash-probe 1", log_lines=8)
        self.save = OsCloudSave()
        self.up = CrashUpload()
        var pipe = MemoryPipe()
        self.game = pipe.end(0)
        self.collector = pipe.end(1)
        self.sent = List[UInt8]()


def _p(h: UInt64) -> UnsafePointer[Probe, MutAnyOrigin]:
    return UnsafePointer[Probe, MutAnyOrigin](unsafe_from_address=Int(h))


@export
def c_new() abi("C") -> UInt64:
    var p = alloc[Probe](1)
    p.unsafe_write(Probe())
    return UInt64(Int(p))


@export
def c_grant(h: UInt64, granted: Int32) abi("C") -> Int32:
    """Opt in (with a fixed id, for the test) or not; then log, set a black box and arm."""
    if granted != 0:
        _ = _p(h)[].tel.grant(install_id_from(0x1111, 0x2222))
        _p(h)[].rep.set_install_id(_p(h)[].tel.install_id())
    for i in range(10):
        _p(h)[].rep.log("frame " + String(i))
    var bb = List[UInt8]()
    for i in range(1000):
        bb.append(UInt8((i * 7) & 0xFF))
    _ = _p(h)[].rep.set_blackbox(bb)
    return Int32(arm_web(_p(h)[].rep, 600, 10000))


@export
def c_crash(h: UInt64, address: UInt64) abi("C") -> Int32:
    return Int32(_inner(address))


@no_inline
def _inner(address: UInt64) -> UInt8:
    var p = UnsafePointer[UInt8, MutAnyOrigin](unsafe_from_address=Int(address))
    return p[]  # CRASH-LINE: a load far outside linear memory traps here


@export
def c_upload_start(h: UInt64) abi("C") -> Int32:
    return Int32(_p(h)[].up.start(_p(h)[].save, 1))


@export
def c_upload_step(h: UInt64, granted: Int32) abi("C") -> Int32:
    var st = _p(h)[].up.step(_p(h)[].save, _p(h)[].game, granted != 0)
    var buf = List[UInt8](length=1 << 20, fill=0)
    var n = poll_bytes(_p(h)[].collector, buf)
    if n > 0:
        _p(h)[].sent = List[UInt8](capacity=n)
        for i in range(n):
            _p(h)[].sent.append(buf[i])
    return Int32(st)


@export
def c_sent_ptr(h: UInt64) abi("C") -> UInt64:
    return UInt64(Int(_p(h)[].sent.unsafe_ptr()))


@export
def c_sent_len(h: UInt64) abi("C") -> Int32:
    return Int32(len(_p(h)[].sent))
