"""W1: the wasm SparseSet core written in Mojo, on dev's `ecs.SparseSet`.

Same exported ABI as the C stand-in (toolchain/standin/sparse_set.c), so the
differential test and the layer A test run against either:

    ss_create(fixed_size) -> handle      ss_add / ss_remove / ss_contains
    ss_len / ss_dense_at / ss_dense_ptr  (zero-copy view of the dense keys)

Differences from the stand-in, both visible to the host:
  * keys in the dense array are Mojo `Int`, which stays 64-bit after the
    retarget (retarget_ir.py), so `ss_key_bytes()` returns 8 and the host
    reads them as BigInt64 (the stand-in has no ss_key_bytes: 4 bytes);
  * parameters and results are Int32 at the ABI, so JS passes plain numbers.

The fixed key range of the stand-in (`fixed_size`) is kept at the ABI: keys
outside [0, fixed_size) are ignored, as there.

Build: experiments/wasm_mojo/build.py
"""

from std.memory import alloc, Layout
from ecs.sparse_set import SparseSet


struct Core(Movable):
    var fixed_size: Int
    var set: SparseSet[Int32]

    def __init__(out self, fixed_size: Int):
        self.fixed_size = fixed_size
        self.set = SparseSet[Int32]()


comptime CorePtr = type_of(alloc[Core](Layout[Core](count=1)).unsafe_leak())


def _core(h: Int32) -> CorePtr:
    return CorePtr(unsafe_from_address=Int(h))


@export
def ss_create(fixed_size: Int32) abi("C") -> Int32:
    var p = alloc[Core](Layout[Core](count=1)).unsafe_leak()
    p.unsafe_write(Core(Int(fixed_size)))
    return Int32(Int(p))


@export
def ss_contains(h: Int32, key: Int32) abi("C") -> Int32:
    ref c = _core(h)[]
    if key < 0 or Int(key) >= c.fixed_size:
        return 0
    return 1 if c.set.contains(Int(key)) else 0


@export
def ss_add(h: Int32, key: Int32) abi("C"):
    ref c = _core(h)[]
    if key < 0 or Int(key) >= c.fixed_size:
        return
    c.set.add(Int(key), key)


@export
def ss_remove(h: Int32, key: Int32) abi("C"):
    _core(h)[].set.remove(Int(key))


@export
def ss_len(h: Int32) abi("C") -> Int32:
    return Int32(len(_core(h)[].set))


@export
def ss_dense_at(h: Int32, i: Int32) abi("C") -> Int32:
    return Int32(_core(h)[].set.key_at(Int(i)))


@export
def ss_dense_ptr(h: Int32) abi("C") -> Int32:
    return Int32(Int(_core(h)[].set._dense.unsafe_ptr()))


@export
def ss_key_bytes() abi("C") -> Int32:
    return 8
