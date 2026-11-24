"""A module that only calls the os_* imports, so a test can drive them from JS (tests/test_os.mjs)."""
from std.memory import alloc
from os_cloud_save import OsCloudSave
from os import os_clipboard_read_request, os_clipboard_write, os_file_read_request, os_file_write, os_poll


@export
def p_clip_write(ptr: UInt64, length: UInt64) abi("C") -> Int32:
    return os_clipboard_write(ptr, length)


@export
def p_clip_request() abi("C") -> Int32:
    return os_clipboard_read_request()


@export
def p_file_write(pp: UInt64, pl: UInt64, dp: UInt64, dl: UInt64) abi("C") -> Int32:
    return os_file_write(pp, pl, dp, dl)


@export
def p_file_request(id: Int32, pp: UInt64, pl: UInt64) abi("C") -> Int32:
    return os_file_read_request(id, pp, pl)


@export
def p_poll(buf: UInt64, cap: UInt64) abi("C") -> Int64:
    return os_poll(buf, cap)


def _str(ptr: UInt64, n: Int) -> String:
    var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var out = String()
    for i in range(n):
        out += chr(Int(p[i]))
    return out^


@export
def p_cs_new() abi("C") -> UInt64:
    """An OsCloudSave kept alive on the heap between calls; the address is the handle the next calls take."""
    var p = alloc[OsCloudSave](1)
    p.unsafe_write(OsCloudSave())
    return UInt64(Int(p))


@export
def p_cs_write(h: UInt64, id: Int32, sp: UInt64, sl: UInt64, dp: UInt64, dl: UInt64) abi("C") -> Int32:
    var p = UnsafePointer[OsCloudSave, MutAnyOrigin](unsafe_from_address=Int(h))
    return Int32(p[].write_request(Int(id), _str(sp, Int(sl)), dp, Int(dl)))


@export
def p_cs_read(h: UInt64, id: Int32, sp: UInt64, sl: UInt64) abi("C") -> Int32:
    var p = UnsafePointer[OsCloudSave, MutAnyOrigin](unsafe_from_address=Int(h))
    return Int32(p[].read_request(Int(id), _str(sp, Int(sl))))


@export
def p_cs_poll(h: UInt64, buf: UInt64, cap: Int32) abi("C") -> Int32:
    var p = UnsafePointer[OsCloudSave, MutAnyOrigin](unsafe_from_address=Int(h))
    return Int32(p[].poll(buf, Int(cap)))
