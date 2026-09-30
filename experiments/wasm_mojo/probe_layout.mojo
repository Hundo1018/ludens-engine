"""W1 probe: do Mojo's compile-time struct offsets hold after the retarget?

Mojo computes size_of / reflect field offsets for the HOST (64-bit
pointers); after retarget_ir.py, LLVM lays the same struct out for wasm32
(32-bit pointers). For each struct, export the baked value and the offset
LLVM computes at run time (address of the field minus the base).
"""
from std.memory import alloc, Layout
from std.sys import size_of

comptime BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())


struct IntsOnly(Movable):
    var a: Int
    var b: Float32
    var c: Int

    def __init__(out self):
        self.a = 0
        self.b = 0
        self.c = 0


struct TwoPtrs(Movable):
    var p: BytePtr
    var q: BytePtr
    var c: Int

    def __init__(out self):
        self.p = BytePtr(unsafe_from_address=16)
        self.q = BytePtr(unsafe_from_address=16)
        self.c = 0


@export
def baked_offset_intsonly_c() abi("C") -> Int32:
    return Int32(reflect[IntsOnly].field_offset[index=2]())


@export
def runtime_offset_intsonly_c() abi("C") -> Int32:
    var s = IntsOnly()
    return Int32(Int(Pointer(to=s.c)) - Int(Pointer(to=s)))


@export
def baked_offset_twoptrs_c() abi("C") -> Int32:
    return Int32(reflect[TwoPtrs].field_offset[index=2]())


@export
def runtime_offset_twoptrs_c() abi("C") -> Int32:
    var s = TwoPtrs()
    return Int32(Int(Pointer(to=s.c)) - Int(Pointer(to=s)))


@export
def baked_size_twoptrs() abi("C") -> Int32:
    return Int32(size_of[TwoPtrs]())
