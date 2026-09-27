"""`FrameArena`: a bump allocator over one allocation, reset per frame (Phase 17.34).

The seam this exists to measure: a naive per-frame scratch buffer is
`List[T]()` built fresh (or `.clear()`-ed and re-`.append()`-ed) every frame,
which either reallocates as it grows or, if pre-sized, still pays a
zero-initialization / element-by-element append cost every frame. `FrameArena`
allocates ONE raw byte buffer up front, then hands out typed sub-spans of it
with a bump pointer; `reset()` just sets the bump pointer back to zero -- no
reallocation, no per-element work, the backing bytes are simply reused
(and left with stale bytes from the previous frame, which is fine: `alloc[T]`
returns UNINITIALIZED memory the caller is expected to write into immediately,
exactly like `List.append`'s destination slot before the append writes it).
`benchmarks/bench_diag.mojo` prices this against `List`-per-frame across an
N sweep (64..65536 records) -- see that file for where the crossover is.

Mechanics, verified on Mojo 1.1.0 / modular 26.6.0
(`/tmp/claude-1000/probe_diag2/p6_sizeof.mojo`, `p8_frame_arena.mojo`): a
single `Allocation[UInt8]` backs the whole arena; `alloc[T](n)` rounds the
current bump offset up to `align_of[T]()`, carves out `n * size_of[T]()` bytes
via `unsafe_offset` + `unsafe_bitcast[T]()`, and returns them as a `Span[T]`.
`size_of`/`align_of` live in `std.sys`, not `std.memory`, and are easy to miss
(the compiler's own fixit says so) since neither this package nor any other
in the engine had needed them before.

Origin note: the returned `Span[T]` is declared `MutUntrackedOrigin` (per the
`mojo-syntax` skill: "use `UntrackedOrigin` if lifetime is managed
explicitly"), not tied to `origin_of(self)`. That is a deliberate, documented
unsafety: `Allocation.unsafe_ptr()` returns a pointer whose tracked origin is
the `Allocation`'s OWN internal field (one level deeper than `self`), which
does not unify with `origin_of(self)` at the type level, and there is no
byte-range-scoped origin to ask for once you've bitcast into the middle of a
buffer anyway -- the same unsafety `unsafe_bitcast`/`unsafe_offset` already
opted into. The caller-facing contract is the same as any frame-scratch
allocator (alloca, a stack arena, etc.): a `Span` returned by `alloc[T]` is
valid only until the next `reset()`, and never held past the frame that
produced it. `pixi run build`'s 0-warnings gate does not catch this class of
misuse; it is a documentation/discipline contract, the same as it would be in
C++.

Overflow policy differs from `LogRing`/`DrawQueue`/`TraceBuffer`: those three
drop-and-count because "drop the newest item, keep going" is a sensible
recovery for a queue. A bump allocator has no such move -- the caller asked
for N elements and there is no safe smaller Span to hand back instead. So
`alloc[T]` both counts the overflow (`overflow_count`, mirroring
`diag.counters.ARENA_OVERFLOW`) AND raises, giving the immediate caller a
chance to catch it and fall back (e.g. skip this frame's batch), while still
leaving the failure visible in `overflow_count` for whoever is watching
`diag` -- "never silent" from `docs/ARCHITECTURE.md` §2 without pretending a
100-element request can be silently served from 4 spare bytes.
"""

from std.sys import size_of, align_of
from std.memory import Layout, Allocation, alloc, dealloc


def _align_up(x: Int, a: Int) -> Int:
    return (x + a - 1) & ~(a - 1)


struct FrameArena(Movable):
    """One `capacity`-byte allocation, bump-allocated by `alloc[T]`, reset by
    `reset()`. Not parameterized on a single element type: one arena instance
    can carve out spans of different `T`s across a frame (debug-draw scratch,
    batched-query scratch, ...), which is the point of a byte-granular arena
    over a `List[T]`-per-purpose scheme."""

    var _alloc: Allocation[UInt8]
    var capacity: Int
    var offset: Int
    var overflow_count: Int

    def __init__(out self, capacity: Int):
        self._alloc = alloc(Layout[UInt8](count=capacity))
        self.capacity = capacity
        self.offset = 0
        self.overflow_count = 0

    def __deinit__(deinit self):
        dealloc(self._alloc^)

    def reset(mut self):
        """Bump the arena back to empty. O(1): does not touch the bytes."""
        self.offset = 0

    def used(self) -> Int:
        return self.offset

    def alloc[T: AnyType](mut self, n: Int) raises -> Span[T, MutUntrackedOrigin]:
        """Carve `n` uninitialized, `align_of[T]()`-aligned elements of `T` out
        of the arena's remaining space. Raises (and counts
        `overflow_count`) if `n` elements do not fit in what's left before the
        next `reset()`."""
        var need = n * size_of[T]()
        var start = _align_up(self.offset, align_of[T]())
        if n < 0 or start + need > self.capacity:
            self.overflow_count += 1
            raise Error(
                "FrameArena: out of space (need "
                + String(need)
                + " bytes at offset "
                + String(start)
                + ", capacity "
                + String(self.capacity)
                + ")"
            )
        self.offset = start + need
        var p = self._alloc.unsafe_ptr().unsafe_offset(start).unsafe_bitcast[
            T
        ]().unsafe_origin_cast[MutUntrackedOrigin]()
        return Span[T, MutUntrackedOrigin](unsafe_ptr=p, length=n)
