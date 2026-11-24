"""Per-segment frame timings and per-frame counters (issue #123): where the time of one frame goes and how much work it did.

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
comptime SEG_AI = 9  # the game's AI update inside the step, as the game reports it (GameMode.ai_ns); inside step like physics
comptime SEG_AUDIO = 10  # the mixer's render work (app_audio_render) since the previous frame ended
comptime SEG_GPU_SHADOW = 11  # GPU time of the shadow passes (timestamp queries; not run where the adapter has none)
comptime SEG_GPU_SCENE = 12  # GPU time of the scene colour pass(es)
comptime SEG_GPU_POST = 13  # GPU time of the post stages and the HUD pass
comptime SEG_GPU_FRAME = 14  # GPU time from the first to the last timestamp of the frame
comptime SEGMENTS = 15
comptime FRAME_RING = 300  # the last 300 frames: five seconds at 60 Hz
comptime STAT_FIELDS = 6  # per segment: avg, p50, p95, p99, max (ns), frames it ran in

comptime CTR_DRAWS = 0  # draw calls the scene's colour pass and the HUD issued
comptime CTR_TRIANGLES = 1  # triangles they drew (indices / 3 times instances; HUD vertices / 3)
comptime CTR_TEXTURE_BYTES = 2  # bytes of every texture the renderer holds (all mip levels and layers)
comptime CTR_PARTICLES = 3  # live particles, as the game reports them (GameMode.counters)
comptime CTR_BODIES = 4  # physics bodies, as the game reports them
comptime CTR_AI_AGENTS = 5  # AI agents that were active in the frame, as the game reports them
comptime COUNTERS = 6
comptime CTR_FIELDS = 3  # per counter: last, avg, max over the frames in the ring



def segment_name(seg: Int) -> String:
    var names: List[String] = [
        "net", "step", "physics", "scene", "push", "hud", "draw", "present", "frame", "ai", "audio",
        "gpu_shadow", "gpu_scene", "gpu_post", "gpu_frame",
    ]
    return names[seg]


def counter_name(c: Int) -> String:
    var names: List[String] = ["draw_calls", "triangles", "texture_bytes", "particles", "bodies", "ai_agents"]
    return names[c]


@always_inline
def now_ns() -> Int:
    return perf_counter_ns()


struct FrameStats(Movable):
    var ring: List[Int64]  # FRAME_RING x SEGMENTS, ns; -1 = did not run in that frame
    var cur: List[Int64]  # the frame being timed
    var ctr_ring: List[Int64]  # FRAME_RING x COUNTERS
    var ctr_cur: List[Int64]
    var audio_pending: Int64  # mixer render ns since the last frame ended; -1 = none
    var head: Int  # the slot the next frame goes to
    var filled: Int

    def __init__(out self):
        self.ring = List[Int64](length=FRAME_RING * SEGMENTS, fill=-1)
        self.cur = List[Int64](length=SEGMENTS, fill=-1)
        self.ctr_ring = List[Int64](length=FRAME_RING * COUNTERS, fill=0)
        self.ctr_cur = List[Int64](length=COUNTERS, fill=0)
        self.audio_pending = -1
        self.head = 0
        self.filled = 0

    def __init__(out self, *, deinit move: Self):
        self.ring = move.ring^
        self.cur = move.cur^
        self.ctr_ring = move.ctr_ring^
        self.ctr_cur = move.ctr_cur^
        self.audio_pending = move.audio_pending
        self.head = move.head
        self.filled = move.filled

    def begin(mut self):
        """Start a frame: forget a frame that raised before `end`. The counters keep the last frame's values until set
        (the texture bytes do not change from frame to frame)."""
        for s in range(SEGMENTS):
            self.cur[s] = -1

    def set_counter(mut self, c: Int, v: Int):
        self.ctr_cur[c] = Int64(v)

    def add_audio(mut self, ns: Int64):
        """Mixer render time between frames (`app_audio_render` runs from the audio callback, not inside a frame): it is
        attributed to the frame that ends next."""
        if ns < 0:
            return
        self.audio_pending = ns if self.audio_pending < 0 else self.audio_pending + ns

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
        if self.audio_pending >= 0:
            self.cur[SEG_AUDIO] = self.audio_pending
            self.audio_pending = -1
        var base = self.head * SEGMENTS
        for s in range(SEGMENTS):
            self.ring[base + s] = self.cur[s]
        var cbase = self.head * COUNTERS
        for c in range(COUNTERS):
            self.ctr_ring[cbase + c] = self.ctr_cur[c]
        self.head = (self.head + 1) % FRAME_RING
        self.filled = min(self.filled + 1, FRAME_RING)

    def _slot(self, k: Int) -> Int:
        """The ring slot of the k-th oldest frame (0 = oldest)."""
        return k if self.filled < FRAME_RING else (self.head + k) % FRAME_RING

    def summary(self, seg: Int) -> List[UInt64]:
        """[avg, p50, p95, p99, max, count] of `seg` over the frames in the ring it ran in (nearest rank, ns; zeros if it
        never ran). avg is the integer mean."""
        var xs = List[Int64]()
        for f in range(self.filled):
            var v = self.ring[f * SEGMENTS + seg]
            if v >= 0:
                xs.append(v)
        var n = len(xs)
        var out = List[UInt64](length=STAT_FIELDS, fill=0)
        if n == 0:
            return out^
        var sum: Int64 = 0
        for i in range(1, n):  # insertion sort: at most FRAME_RING values, and only when the stats are read
            var v = xs[i]
            var j = i - 1
            while j >= 0 and xs[j] > v:
                xs[j + 1] = xs[j]
                j -= 1
            xs[j + 1] = v
        for i in range(n):
            sum += xs[i]
        out[0] = UInt64(sum // Int64(n))
        out[1] = UInt64(xs[rank(50, n)])
        out[2] = UInt64(xs[rank(95, n)])
        out[3] = UInt64(xs[rank(99, n)])
        out[4] = UInt64(xs[n - 1])
        out[5] = UInt64(n)
        return out^

    def counter_summary(self, c: Int) -> List[UInt64]:
        """[last, avg, max] of counter `c` over the frames in the ring (zeros before the first frame)."""
        var out = List[UInt64](length=CTR_FIELDS, fill=0)
        if self.filled == 0:
            return out^
        var sum: Int64 = 0
        var mx: Int64 = 0
        for f in range(self.filled):
            var v = self.ctr_ring[f * COUNTERS + c]
            sum += v
            mx = max(mx, v)
        out[0] = UInt64(self.ctr_ring[self._slot(self.filled - 1) * COUNTERS + c])
        out[1] = UInt64(sum // Int64(self.filled))
        out[2] = UInt64(mx)
        return out^

    def write(self, out_ptr: UInt64) -> Int32:
        """SEGMENTS x STAT_FIELDS u64 at `out_ptr` (see `summary`), then COUNTERS x CTR_FIELDS u64 (see `counter_summary`);
        returns the frames in the ring."""
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        for s in range(SEGMENTS):
            var r = self.summary(s)
            for k in range(STAT_FIELDS):
                out[s * STAT_FIELDS + k] = r[k]
        for c in range(COUNTERS):
            var r = self.counter_summary(c)
            for k in range(CTR_FIELDS):
                out[SEGMENTS * STAT_FIELDS + c * CTR_FIELDS + k] = r[k]
        return Int32(self.filled)

    def write_ring(self, out_ptr: UInt64) -> Int32:
        """The frames in the ring, oldest first, as (SEGMENTS + COUNTERS) i64 each: segment ns (-1 = did not run), then the
        counters. `scripts/frame_trace.py` turns them into a Chrome trace. Returns the frame count."""
        var out = Pointer[Int64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        var w = SEGMENTS + COUNTERS
        for k in range(self.filled):
            var slot = self._slot(k)
            for s in range(SEGMENTS):
                out[k * w + s] = self.ring[slot * SEGMENTS + s]
            for c in range(COUNTERS):
                out[k * w + SEGMENTS + c] = self.ctr_ring[slot * COUNTERS + c]
        return Int32(self.filled)

    def frame_ns(self, k: Int, seg: Int) -> Int64:
        """Segment `seg` of the k-th oldest frame in the ring (-1 = did not run)."""
        return self.ring[self._slot(k) * SEGMENTS + seg]


def rank(pct: Int, n: Int) -> Int:
    """Index of the nearest-rank percentile in a sorted list of n values."""
    return max((pct * n + 99) // 100 - 1, 0)
