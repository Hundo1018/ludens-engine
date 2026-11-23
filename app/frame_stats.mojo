"""Per-segment frame timings (issue #123, first slice): where the CPU time of one frame goes.

`AppOf.frame` (app/main.mojo) times each part of its frame with one clock, `std.time.perf_counter_ns` (natively the OS
monotonic clock; in the wasm64 build the runtime's `host_now_ns` import, i.e. `performance.now()`), and keeps the last
`FRAME_RING` frames here. `app_frame_stats` reads p50 / p95 / max per segment over that ring; `scripts/frame_budget.py`
prints them against a 144 Hz frame. The native runner (app/frame_budget.mojo) fills the same struct, so both tables
have the same rows.

A segment that did not run in a frame (the draw while the GPU is still being set up, or under node where there is no
WebGPU) is recorded as "did not run", not as 0 ns: its percentiles are over the frames it ran in, and `count` says how
many those were. A segment that runs twice in a frame (the canvas draw and a capture draw) adds up."""
from std.time import perf_counter_ns

comptime SEG_NET = 0  # app._net: the host's queued packets
comptime SEG_STEP = 1  # input + game step + its sound cues (physics included)
comptime SEG_PHYSICS = 2  # the fixed ticks inside the step, as the game reports them (GameMode.physics_ns)
comptime SEG_SCENE = 3  # building the frame's draw list (GameMode.scene)
comptime SEG_PUSH = 4  # handing each draw item to the renderer
comptime SEG_HUD = 5  # GameMode.hud + Hud.set
comptime SEG_DRAW = 6  # the renderer's draw: encode and submit (CPU side; the GPU's own time is not in it)
comptime SEG_PRESENT = 7  # surface acquire + present
comptime SEG_FRAME = 8  # the whole app_frame call
comptime SEGMENTS = 9
comptime FRAME_RING = 256
comptime STAT_FIELDS = 4  # per segment: p50, p95, max (ns), frames it ran in



def segment_name(seg: Int) -> String:
    var names: List[String] = ["net", "step", "physics", "scene", "push", "hud", "draw", "present", "frame"]
    return names[seg]


@always_inline
def now_ns() -> Int:
    return perf_counter_ns()


struct FrameStats(Movable):
    var ring: List[Int64]  # FRAME_RING x SEGMENTS, ns; -1 = did not run in that frame
    var cur: List[Int64]  # the frame being timed
    var head: Int  # the slot the next frame goes to
    var filled: Int

    def __init__(out self):
        self.ring = List[Int64](length=FRAME_RING * SEGMENTS, fill=-1)
        self.cur = List[Int64](length=SEGMENTS, fill=-1)
        self.head = 0
        self.filled = 0

    def __init__(out self, *, deinit move: Self):
        self.ring = move.ring^
        self.cur = move.cur^
        self.head = move.head
        self.filled = move.filled

    def begin(mut self):
        """Start a frame: forget a frame that raised before `end`."""
        for s in range(SEGMENTS):
            self.cur[s] = -1

    def add(mut self, seg: Int, ns: Int64):
        if ns < 0:
            return
        if self.cur[seg] < 0:
            self.cur[seg] = 0
        self.cur[seg] += ns

    def lap(mut self, seg: Int, t0: Int) -> Int:
        """Add the time since `t0` to `seg`; returns now, the start of the next segment."""
        var t1 = now_ns()
        self.add(seg, Int64(t1 - t0))
        return t1

    def end(mut self):
        var base = self.head * SEGMENTS
        for s in range(SEGMENTS):
            self.ring[base + s] = self.cur[s]
        self.head = (self.head + 1) % FRAME_RING
        self.filled = min(self.filled + 1, FRAME_RING)

    def summary(self, seg: Int) -> List[UInt64]:
        """[p50, p95, max, count] of `seg` over the frames in the ring it ran in (nearest rank; zeros if it never ran)."""
        var xs = List[Int64]()
        for f in range(self.filled):
            var v = self.ring[f * SEGMENTS + seg]
            if v >= 0:
                xs.append(v)
        var n = len(xs)
        var out = List[UInt64](length=STAT_FIELDS, fill=0)
        if n == 0:
            return out^
        for i in range(1, n):  # insertion sort: at most FRAME_RING values, and only when the stats are read
            var v = xs[i]
            var j = i - 1
            while j >= 0 and xs[j] > v:
                xs[j + 1] = xs[j]
                j -= 1
            xs[j + 1] = v
        out[0] = UInt64(xs[max((50 * n + 99) // 100 - 1, 0)])
        out[1] = UInt64(xs[max((95 * n + 99) // 100 - 1, 0)])
        out[2] = UInt64(xs[n - 1])
        out[3] = UInt64(n)
        return out^

    def write(self, out_ptr: UInt64) -> Int32:
        """SEGMENTS x STAT_FIELDS u64 at `out_ptr` (see `summary`); returns the frames in the ring."""
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        for s in range(SEGMENTS):
            var r = self.summary(s)
            for k in range(STAT_FIELDS):
                out[s * STAT_FIELDS + k] = r[k]
        return Int32(self.filled)
