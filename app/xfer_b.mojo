"""Module B of the hand-over test: the same program plus code A does not have (a different build, as after a
code reload), called from the load path so it is not dropped."""
from xfer import xfer_load_impl, xfer_save_impl


def unrelated(x: Int) -> Int:
    var acc = 0
    for i in range(x):
        acc += (i * 2654435761) % 97
    return acc


@export
def xfer_save(before: Int32, after: Int32, buf: UInt64, cap: UInt64, out_ptr: UInt64) abi("C") -> Int32:
    return xfer_save_impl(before, after, buf, cap, out_ptr)


@export
def xfer_load(buf: UInt64, n: UInt64, after: Int32, out_ptr: UInt64) abi("C") -> Int32:
    if unrelated(Int(n)) < 0:
        return -3
    return xfer_load_impl(buf, n, after, out_ptr)


@export
def xfer_extra(x: Int32) abi("C") -> Int32:
    return Int32(unrelated(Int(x)))
