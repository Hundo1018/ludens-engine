"""The layout of the frame stats (app/frame_stats.mojo) as the scripts read it: segment and counter names in ring order, the
fields of `app_frame_stats`, and the parsers of the native runner's text output. `tests/test_perf_gate.py` checks these lists
against the Mojo source, so a segment added there and not here fails a test instead of shifting every column."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SEGMENTS = [
    "net", "step", "physics", "scene", "push", "hud", "draw", "present", "frame", "ai", "audio",
    "gpu_shadow", "gpu_scene", "gpu_post", "gpu_frame",
]
COUNTERS = ["draw_calls", "triangles", "texture_bytes", "particles", "bodies", "ai_agents"]
STAT_FIELDS = ["avg", "p50", "p95", "p99", "max", "count"]  # per segment, nanoseconds, frames it ran in
CTR_FIELDS = ["last", "avg", "max"]
FRAME_RING = 300
# inside another segment: do not add them to it
INSIDE_STEP = {"physics", "ai"}
GPU = {"gpu_shadow", "gpu_scene", "gpu_post", "gpu_frame"}


def mojo_layout() -> dict:
    """The same lists read from app/frame_stats.mojo, for the consistency test."""
    src = (ROOT / "app/frame_stats.mojo").read_text()
    names = re.search(r"def segment_name.*?names: List\[String\] = \[(.*?)\]", src, re.S).group(1)
    cnames = re.search(r"def counter_name.*?names: List\[String\] = \[(.*?)\]", src, re.S).group(1)
    const = {k: int(v) for k, v in re.findall(r"^comptime (\w+) = (\d+)", src, re.M)}
    return {
        "segments": re.findall(r'"(\w+)"', names), "counters": re.findall(r'"(\w+)"', cnames),
        "SEGMENTS": const["SEGMENTS"], "COUNTERS": const["COUNTERS"], "STAT_FIELDS": const["STAT_FIELDS"],
        "CTR_FIELDS": const["CTR_FIELDS"], "FRAME_RING": const["FRAME_RING"],
        "seg_ids": {k[4:].lower(): v for k, v in const.items() if k.startswith("SEG_")},
        "ctr_ids": {k[4:].lower(): v for k, v in const.items() if k.startswith("CTR_") and k != "CTR_FIELDS"},
    }


def parse_native(out: str) -> dict:
    """`seg <name> avg A p50 B p95 C p99 D max E count N`, `ctr <name> last L avg A max M` and `frame K v0 v1 ...` lines."""
    stats = {}
    for name, *v in re.findall(r"^seg (\w+) avg (\d+) p50 (\d+) p95 (\d+) p99 (\d+) max (\d+) count (\d+)$", out, re.M):
        stats[name] = dict(zip(STAT_FIELDS, map(int, v), strict=True))
    counters = {}
    for name, *v in re.findall(r"^ctr (\w+) last (\d+) avg (\d+) max (\d+)$", out, re.M):
        counters[name] = dict(zip(CTR_FIELDS, map(int, v), strict=True))
    ring = [[int(x) for x in line.split()[2:]] for line in out.splitlines() if line.startswith("frame ") and not line.startswith("frame_budget")]
    gpu = re.search(r"gpu_timing (True|False)", out)
    return {"stats": stats, "counters": counters, "ring": ring, "gpu_timing": bool(gpu and gpu.group(1) == "True")}


def from_node(d: dict) -> dict:
    """The JSON of scripts/frame_stats_node.mjs in the same shape as `parse_native`."""
    return {
        "stats": {n: dict(zip(STAT_FIELDS, row, strict=True)) for n, row in zip(SEGMENTS, d["stats"], strict=True)},
        "counters": {n: dict(zip(CTR_FIELDS, row, strict=True)) for n, row in zip(COUNTERS, d["counters"], strict=True)},
        "ring": d["ring"], "gpu_timing": False,
    }
