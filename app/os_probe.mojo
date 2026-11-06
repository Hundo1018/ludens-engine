"""A module that only calls the os_* imports, so a test can drive them from JS (tests/test_os.mjs)."""
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
