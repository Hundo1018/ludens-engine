"""The in-game frame-time overlay (F3, issue #123): average / p95 / p99 of every timed segment over the last 300 frames, and
the frame counters. Built from `FrameStats` as a draw list the host puts over the HUD (app/main.mojo), so the same text is
what a test reads."""
from app.frame_stats import (
    FrameStats, FRAME_RING, SEGMENTS, COUNTERS, SEG_NET, SEG_GPU_SHADOW, SEG_GPU_FRAME, segment_name, counter_name,
)
from ui.draw import Color, DrawList
from ui.geom import Rect

comptime ROW_H: Float32 = 16.0
comptime PAD: Float32 = 6.0
comptime TEXT_SIZE: Float32 = 12.0
comptime PANEL_W: Float32 = 392.0


def ms_text(ns: UInt64) -> String:
    """Milliseconds with three decimals from integer nanoseconds: 1234567 -> "1.235"."""
    var us = (Int(ns) + 500) // 1000
    var frac = String(us % 1000)
    while frac.byte_length() < 3:
        frac = String("0") + frac
    return String(us // 1000) + "." + frac


def _pad(s: String, width: Int) -> String:
    var out = s
    while out.byte_length() < width:
        out += " "
    return out


def _left(s: String, width: Int) -> String:
    var out = s
    while out.byte_length() < width:
        out = String(" ") + out
    return out


def overlay_lines(stats: FrameStats) -> List[String]:
    """One text line per row: a header, one per segment that ran in the ring, one per counter. GPU rows are replaced by a
    single "gpu  absent" line when no frame in the ring has GPU timing."""
    var lines = List[String]()
    lines.append(_pad("frame ms, last " + String(stats.filled) + " of " + String(FRAME_RING), 24) + "avg    p95    p99    max")
    var gpu_seen = False
    for s in range(SEGMENTS):
        var r = stats.summary(s)
        if s >= SEG_GPU_SHADOW and s <= SEG_GPU_FRAME and r[5] > 0:
            gpu_seen = True
        if r[5] == 0:
            continue
        lines.append(
            _pad(segment_name(s), 12) + _left(ms_text(r[0]), 6) + " " + _left(ms_text(r[2]), 6) + " "
            + _left(ms_text(r[3]), 6) + " " + _left(ms_text(r[4]), 6)
        )
    if not gpu_seen:
        lines.append("gpu         absent (no timestamp queries)")
    for c in range(COUNTERS):
        var r = stats.counter_summary(c)
        lines.append(_pad(counter_name(c), 16) + _left(String(r[0]), 10) + "  max " + _left(String(r[2]), 10))
    return lines^


def perf_overlay(stats: FrameStats, x: Float32, y: Float32) -> DrawList:
    """The overlay as a draw list with its top-left corner at (x, y): a dark panel and one text row per line."""
    var lines = overlay_lines(stats)
    var dl = DrawList()
    dl.fill(Rect(x, y, PANEL_W, PAD * 2 + ROW_H * Float32(len(lines))), Color(0.02, 0.02, 0.05, 0.82))
    for i in range(len(lines)):
        dl.text(Rect(x + PAD, y + PAD + ROW_H * Float32(i), PANEL_W - PAD * 2, ROW_H), lines[i], Color(0.9, 0.95, 1.0, 1.0), TEXT_SIZE)
    return dl^
