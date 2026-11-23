"""Mixing cost per 128-frame block for N voices (ludens-engine #120), on native and wasm64 from one source.

`run` is the median wall time of `Mixer.render(out, 128)` over `blocks` blocks with `voices` voices playing (plain stereo
clips, or positioned ones that each run a miniaudio Spatializer). One block is 128 / 48000 s = 2.667 ms of audio, which
is the budget a worklet callback has."""
from audio_scene import SCENE_BLOCK, bench_blocks
from std.sys import argv
from std.time import perf_counter_ns


def _median(mut v: List[UInt64]) -> UInt64:
    for i in range(1, len(v)):
        var x = v[i]
        var j = i - 1
        while j >= 0 and v[j] > x:
            v[j + 1] = v[j]
            j -= 1
        v[j + 1] = x
    return v[len(v) // 2]


def run(voices: Int, spatial: Bool, blocks: Int) raises -> UInt64:
    var m = bench_blocks(voices, spatial, blocks)
    var out = List[Float32]()
    m.render(out, SCENE_BLOCK)  # warm-up block, not counted
    var times = List[UInt64]()
    for _ in range(blocks):
        var t0 = perf_counter_ns()
        m.render(out, SCENE_BLOCK)
        times.append(UInt64(perf_counter_ns() - t0))
    return _median(times)


@export
def audio_bench_run(voices: Int32, spatial: Int32, blocks: Int32, out_ptr: UInt64) abi("C") -> Int32:
    """Writes the median ns per block to out_ptr (1 x u64). 0 = ok."""
    try:
        var ns = run(Int(voices), spatial != 0, Int(blocks))
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = ns
        return 0
    except e:
        print("audio_bench_run:", e)
        return -1


def main() raises:
    var a = argv()
    print(run(Int(atol(String(a[1]))), atol(String(a[2])) != 0, Int(atol(String(a[3])))))
