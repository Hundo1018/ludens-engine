# tier: unit
"""`FrameArena` contract: typed bump allocation, alignment, `reset()` reuse,
and the raise+count overflow policy (see `diag/arena.mojo` module docstring
for why arena overflow raises instead of dropping like the other three
diag containers)."""

from harness.runner import Suite
from diag.arena import FrameArena


def main() raises:
    var s = Suite("diag_arena")

    # --- ordinary: alloc a typed span, write through it, read it back ---
    var arena = FrameArena(256)
    var floats = arena.alloc[Float32](4)
    for i in range(4):
        floats[i] = Float32(i) * 2.0
    s.check(len(floats) == 4, "ordinary: span length matches request")
    var sum_ok = True
    for i in range(4):
        if floats[i] != Float32(i) * 2.0:
            sum_ok = False
    s.check(sum_ok, "ordinary: values written survive through the span")
    s.eqi(arena.used(), 16, "ordinary: 4 x float32 bumps offset by 16 bytes")

    # --- alignment: a smaller type after a larger one must still round-trip ---
    var arena2 = FrameArena(256)
    _ = arena2.alloc[UInt8](1)  # misalign the offset at 1 byte
    var ints = arena2.alloc[Int64](2)  # must round up to 8-byte alignment
    ints[0] = 111
    ints[1] = 222
    s.eqi(Int(ints[0]), 111, "alignment: first Int64 correct after realignment")
    s.eqi(Int(ints[1]), 222, "alignment: second Int64 correct")

    # --- reset() reuse: bump pointer goes back to zero, old span is scratch ---
    arena2.reset()
    s.eqi(arena2.used(), 0, "reset: offset back to zero")
    var reused = arena2.alloc[Int64](1)
    reused[0] = 999
    s.eqi(Int(reused[0]), 999, "reset: freshly allocated span writable again")

    # --- extreme: exactly-full allocation succeeds, one more overflows ---
    var tight = FrameArena(16)
    var exact = tight.alloc[Int64](2)  # exactly 16 bytes, exactly fills it
    exact[0] = 1
    exact[1] = 2
    s.eqi(tight.used(), 16, "exactly-full: bump offset equals capacity")
    s.eqi(tight.overflow_count, 0, "exactly-full: no overflow yet")
    var raised = False
    try:
        _ = tight.alloc[Int64](1)
    except:
        raised = True
    s.check(raised, "overflow: alloc past capacity raises")
    s.eqi(tight.overflow_count, 1, "overflow: exactly one overflow counted")

    # --- extreme: zero-capacity arena -- any nonzero alloc overflows ---
    var empty = FrameArena(0)
    var raised0 = False
    try:
        _ = empty.alloc[UInt8](1)
    except:
        raised0 = True
    s.check(raised0, "zero capacity: any alloc overflows")
    s.eqi(empty.overflow_count, 1, "zero capacity: overflow counted")
    # a zero-length alloc on a zero-capacity arena is legal (needs 0 bytes).
    var zero_len = empty.alloc[UInt8](0)
    s.eqi(len(zero_len), 0, "zero-length alloc on zero-capacity arena succeeds")

    # --- parity: FrameArena vs List-per-frame produce IDENTICAL content for
    #     the same synthetic fill (`benchmarks/bench_diag.mojo` prices the
    #     two; this is the correctness half of that seam -- see
    #     `docs/CATEGORY.md` §2 for why a swap seam needs both) ---
    comptime N = 500
    var via_list = List[Int64](capacity=N)
    for i in range(N):
        via_list.append(Int64(i * i))
    var arena3 = FrameArena(N * 8 + 64)
    var via_arena = arena3.alloc[Int64](N)
    for i in range(N):
        via_arena[i] = Int64(i * i)
    var parity_ok = True
    for i in range(N):
        if via_list[i] != via_arena[i]:
            parity_ok = False
    s.check(parity_ok, "parity: arena-filled and List-filled content agree")

    s.finish()
