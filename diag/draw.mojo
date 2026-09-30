"""`DrawQueue[dtype]`: a fixed-capacity debug-draw command queue (Phase 17.9).

Points are `SIMD[dtype, 4]` with `dtype` a struct PARAMETER, not a hardcoded
`DType.float32` -- so `diag` needs no `geometry` import (layer 0 stays at zero
engine deps) and `DrawQueue[WorldType]` still accepts `geometry.vec.Vec3`
values directly, because `Vec3 = SIMD[WorldType, 4]` unifies with
`SIMD[dtype, 4]` by construction, not by a shared base type. If Phase 17.8
ever switches `WorldType` to `f64`, `DrawQueue` needs no change.

Colors are always `SIMD[DType.float32, 4]` (rgba) regardless of `dtype`:
color is a rendering-side quantity, not a world-space coordinate, so it does
not track the world's numeric precision.

Commands are one flat, tagged struct (`DrawCommand`) rather than a
`Variant[Line, Sphere, ...]` -- six shape kinds share almost every field
(two points, a radius/size, a color, a lifetime), and a flat struct keeps
`commands: List[DrawCommand[dtype]]` a single contiguous, homogeneous
allocation instead of a `List[Variant[...]]` boxing/tag-dispatch layer, which
matters for a queue meant to be pushed into every frame from hot solver code.

Lifetime semantics: `life` is how many MORE `tick()` calls the command
survives after the one that pushed it -- `life=0` means "this frame only" (it
renders for the frame it was pushed in, then `tick()` removes it before the
next frame); `life=N` means it also survives `tick()` being called N more
times. `tick()` is the caller's job to invoke once per frame (after whatever
reads/renders the queue that frame); `docs/ARCHITECTURE.md` says engine
packages never print, so nothing in this module renders anything -- `tick()`
only ages/expires, and a test/renderer reads `commands` directly.

Capacity policy: drop-newest + count, same as `LogRing` and the general
"capacity/budget overflow" row in `docs/ARCHITECTURE.md` §2 -- a full queue
drops the command that didn't fit and increments `dropped`, it never silently
discards without counting and never grows unboundedly on a hot path.
"""


struct Kind:
    comptime LINE: Int = 0
    comptime SPHERE: Int = 1
    comptime BOX: Int = 2
    comptime ARROW: Int = 3
    comptime TEXT: Int = 4
    comptime POINT: Int = 5


@fieldwise_init
struct DrawCommand[dtype: DType](Copyable, Movable):
    var kind: Int
    var p0: SIMD[Self.dtype, 4]
    var p1: SIMD[Self.dtype, 4]
    var radius: Scalar[Self.dtype]
    var color: SIMD[DType.float32, 4]
    var life: Int
    var text: String


struct DrawQueue[dtype: DType](Movable):
    """Fixed-capacity debug-draw command queue over point type `SIMD[dtype,4]`."""

    var commands: List[DrawCommand[Self.dtype]]
    var capacity: Int
    var dropped: Int

    def __init__(out self, capacity: Int):
        self.commands = List[DrawCommand[Self.dtype]](capacity=capacity)
        self.capacity = capacity
        self.dropped = 0

    def _push(mut self, var cmd: DrawCommand[Self.dtype]):
        if len(self.commands) < self.capacity:
            self.commands.append(cmd^)
        else:
            self.dropped += 1

    def line(
        mut self,
        a: SIMD[Self.dtype, 4],
        b: SIMD[Self.dtype, 4],
        color: SIMD[DType.float32, 4],
        life: Int = 0,
    ):
        self._push(DrawCommand[Self.dtype](Kind.LINE, a, b, 0, color, life, ""))

    def sphere(
        mut self,
        center: SIMD[Self.dtype, 4],
        radius: Scalar[Self.dtype],
        color: SIMD[DType.float32, 4],
        life: Int = 0,
    ):
        self._push(
            DrawCommand[Self.dtype](
                Kind.SPHERE, center, center, radius, color, life, ""
            )
        )

    def box(
        mut self,
        lo: SIMD[Self.dtype, 4],
        hi: SIMD[Self.dtype, 4],
        color: SIMD[DType.float32, 4],
        life: Int = 0,
    ):
        self._push(DrawCommand[Self.dtype](Kind.BOX, lo, hi, 0, color, life, ""))

    def arrow(
        mut self,
        origin: SIMD[Self.dtype, 4],
        tip: SIMD[Self.dtype, 4],
        color: SIMD[DType.float32, 4],
        life: Int = 0,
    ):
        self._push(
            DrawCommand[Self.dtype](Kind.ARROW, origin, tip, 0, color, life, "")
        )

    def text(
        mut self,
        pos: SIMD[Self.dtype, 4],
        message: String,
        color: SIMD[DType.float32, 4],
        life: Int = 0,
    ):
        self._push(
            DrawCommand[Self.dtype](
                Kind.TEXT, pos, pos, 0, color, life, message
            )
        )

    def point(
        mut self,
        pos: SIMD[Self.dtype, 4],
        color: SIMD[DType.float32, 4],
        life: Int = 0,
    ):
        self._push(DrawCommand[Self.dtype](Kind.POINT, pos, pos, 0, color, life, ""))

    def tick(mut self):
        """Age every command by one frame; drop those whose lifetime expired.
        A `life=0` command is removed by the FIRST `tick()` after it was
        pushed (it was only meant for the frame it was pushed in)."""
        var kept = List[DrawCommand[Self.dtype]](capacity=len(self.commands))
        for ref c in self.commands:
            if c.life > 0:
                var nc = c.copy()
                nc.life -= 1
                kept.append(nc^)
        self.commands = kept^

    def clear(mut self):
        self.commands.clear()
        self.dropped = 0

    def count(self) -> Int:
        return len(self.commands)
