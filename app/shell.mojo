"""Skeleton shell entry: a deterministic step function the parity gate runs on both targets.

The real shell (window, input, net_*) lands around this; the gate stays the same: build this
entry with `--target native` and `--target wasm64` from wasm.toml and compare the results."""
from std.ffi import external_call


# One source, both targets: wasm64 gets these from ludens-wasm-rt's runtime, native links
# libwasmrt_math.a, so both use the same musl sinf / cosf.
def _sin(x: Float32) -> Float32:
    return external_call["wrt_sinf", Float32](x)


def _cos(x: Float32) -> Float32:
    return external_call["wrt_cosf", Float32](x)


@export
def shell_step(ticks: Int32) abi("C") -> UInt64:
    """FNV-1a over the bit patterns of a sin/cos orbit: any libm or float difference changes it."""
    var h = UInt64(0xCBF29CE484222325)
    var x = Float32(0.25)
    for i in range(Int(ticks)):
        x = _sin(x) * Float32(1.5) + _cos(x + Float32(i)) * Float32(0.5)
        h = (h ^ UInt64(x.to_bits())) * UInt64(0x100000001B3)
    return h


def main():
    print(shell_step(10000))
