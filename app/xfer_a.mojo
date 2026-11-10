"""Module A of the hand-over test: exactly the shared program (ludens-core 17.91)."""
from xfer import xfer_load_impl, xfer_save_impl


@export
def xfer_save(before: Int32, after: Int32, buf: UInt64, cap: UInt64, out_ptr: UInt64) abi("C") -> Int32:
    return xfer_save_impl(before, after, buf, cap, out_ptr)


@export
def xfer_load(buf: UInt64, n: UInt64, after: Int32, out_ptr: UInt64) abi("C") -> Int32:
    return xfer_load_impl(buf, n, after, out_ptr)
