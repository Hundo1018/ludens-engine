# tier: unit
# The frame ring (app/frame_stats.mojo) and the overlay text (app/perf_overlay.mojo) against worked values, no GPU.
#   percentiles   100 frames of 1..100 us: avg 50.5 us -> 50 (integer), p50 50, p95 95, p99 99, max 100
#   300 frames    the ring holds the last 300: after 450 frames of value k the oldest kept is frame 150
#   did not run   a segment recorded in some frames only has count = those frames, not 300, and its percentiles skip the rest
#   counters      last / avg / max over the ring; a counter that is not set again keeps its value (texture bytes)
#   audio         mixer render ns between frames lands in the next frame that ends; several calls add up
#   ring export   write_ring lists the frames oldest first, 21 values each
#   overlay       the text rows: ms with three decimals, the gpu row says "absent" when no frame had GPU timing
from harness.runner import Suite
from app.frame_stats import (
    FrameStats, FRAME_RING, SEGMENTS, COUNTERS, STAT_FIELDS, CTR_DRAWS, CTR_BODIES, CTR_TEXTURE_BYTES,
    SEG_STEP, SEG_PHYSICS, SEG_AI, SEG_AUDIO, SEG_GPU_FRAME, SEG_FRAME,
)
from app.perf_overlay import ms_text, overlay_lines
from wgpu import raw_alloc


def main() raises:
    var s = Suite("frame_stats")

    # percentiles over 1..100 us
    var a = FrameStats()
    for i in range(100):
        a.begin()
        a.add(SEG_STEP, Int64((i + 1) * 1000))
        a.end()
    var r = a.summary(SEG_STEP)
    s.eqi(Int(r[0]), 50500, "avg of 1..100 us is 50.5 us")
    s.eqi(Int(r[1]), 50000, "p50 of 1..100 us")
    s.eqi(Int(r[2]), 95000, "p95 of 1..100 us")
    s.eqi(Int(r[3]), 99000, "p99 of 1..100 us")
    s.eqi(Int(r[4]), 100000, "max of 1..100 us")
    s.eqi(Int(r[5]), 100, "count 100")

    # the ring keeps 300
    var b = FrameStats()
    for i in range(450):
        b.begin()
        b.add(SEG_STEP, Int64(i))
        b.end()
    s.eqi(b.filled, FRAME_RING, "a ring of 300 frames")
    s.eqi(FRAME_RING, 300, "FRAME_RING is 300")
    s.eqi(Int(b.frame_ns(0, SEG_STEP)), 150, "the oldest frame kept after 450 is frame 150")
    s.eqi(Int(b.frame_ns(299, SEG_STEP)), 449, "the newest is frame 449")
    var rb = b.summary(SEG_STEP)
    s.eqi(Int(rb[4]), 449, "max over the ring is 449")
    s.eqi(Int(rb[0]), (150 + 449) // 2, "avg over frames 150..449 is 299 (integer mean of 299.5)")

    # a segment that ran in some frames only
    var c = FrameStats()
    for i in range(10):
        c.begin()
        c.add(SEG_STEP, 100)
        if i % 2 == 0:
            c.add(SEG_PHYSICS, Int64(1000 * (i + 1)))
        c.add(SEG_AI, -1)  # -1 records nothing
        c.end()
    var rp = c.summary(SEG_PHYSICS)
    s.eqi(Int(rp[5]), 5, "physics ran in 5 of 10 frames: count 5")
    s.eqi(Int(rp[0]), 5000, "avg over those 5 only (1, 3, 5, 7, 9 ms -> 5 ms)")
    s.eqi(Int(c.summary(SEG_AI)[5]), 0, "a segment that never ran has count 0, not 10 zero-length frames")
    s.eqi(Int(c.frame_ns(1, SEG_PHYSICS)), -1, "a frame without the segment holds -1")

    # counters
    var d = FrameStats()
    d.set_counter(CTR_TEXTURE_BYTES, 4096)  # set once, kept by the frames that follow
    for i in range(4):
        d.begin()
        d.set_counter(CTR_DRAWS, [3, 9, 5, 4][i])
        d.set_counter(CTR_BODIES, 10 + i)
        d.end()
    var cd = d.counter_summary(CTR_DRAWS)
    s.eqi(Int(cd[0]), 4, "draw calls: last 4")
    s.eqi(Int(cd[1]), 5, "draw calls: avg (3 + 9 + 5 + 4) / 4 = 5")
    s.eqi(Int(cd[2]), 9, "draw calls: max 9")
    s.eqi(Int(d.counter_summary(CTR_TEXTURE_BYTES)[2]), 4096, "a counter not set again keeps its value")
    s.eqi(Int(d.counter_summary(CTR_BODIES)[0]), 13, "bodies: last 13")
    s.eqi(Int(FrameStats().counter_summary(CTR_DRAWS)[2]), 0, "no frames: zeros")

    # audio render time between frames
    var e = FrameStats()
    e.begin()
    e.end()
    e.add_audio(300)
    e.add_audio(200)
    e.add_audio(-1)
    e.begin()
    e.end()
    e.begin()
    e.end()
    s.eqi(Int(e.frame_ns(0, SEG_AUDIO)), -1, "no mixer work before frame 0: did not run")
    s.eqi(Int(e.frame_ns(1, SEG_AUDIO)), 500, "two mixer renders (300 + 200 ns) land in the next frame that ends")
    s.eqi(Int(e.frame_ns(2, SEG_AUDIO)), -1, "and are not counted again")

    # ring export: oldest first, 21 values a frame
    var f = FrameStats()
    for i in range(FRAME_RING + 5):
        f.begin()
        f.add(SEG_FRAME, Int64(1000 + i))
        f.set_counter(CTR_DRAWS, i)
        f.end()
    var buf = raw_alloc[Int64]((SEGMENTS + COUNTERS) * FRAME_RING)
    var n = f.write_ring(UInt64(Int(buf)))
    s.eqi(Int(n), FRAME_RING, "write_ring returns 300 frames")
    var w = SEGMENTS + COUNTERS
    s.eqi(Int(buf[SEG_FRAME]), 1005, "the first exported frame is frame 5")
    s.eqi(Int(buf[SEG_STEP]), -1, "a segment that did not run exports -1")
    s.eqi(Int(buf[SEGMENTS + CTR_DRAWS]), 5, "its draw counter is 5")
    s.eqi(Int(buf[(FRAME_RING - 1) * w + SEG_FRAME]), 1304, "the last exported frame is frame 304")
    buf.unsafe_free()

    # text
    s.check(ms_text(1234567) == "1.235", "1234567 ns is 1.235 ms")
    s.check(ms_text(0) == "0.000", "0 ns")
    s.check(ms_text(999) == "0.001", "999 ns rounds to 0.001 ms")
    var lines = overlay_lines(a)
    var text = String("\n").join(lines)
    s.check("step" in text and "0.051" in text and "0.095" in text and "0.099" in text, "the step row shows avg 0.051 (50500 ns), p95 0.095, p99 0.099 ms")
    s.check("absent" in text, "no GPU frames: the overlay says the GPU rows are absent")
    var g = FrameStats()
    g.begin()
    g.add(SEG_GPU_FRAME, 2_000_000)
    g.end()
    s.check("absent" not in String("\n").join(overlay_lines(g)), "with GPU timing the absent row is gone")
    s.check("draw_calls" in text and "bodies" in text and "ai_agents" in text, "the overlay lists the six counters")
    s.eqi(STAT_FIELDS, 6, "six stat fields: avg, p50, p95, p99, max, count")
    s.finish()
