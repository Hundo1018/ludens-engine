"""Snapshot cost against the entity count (H3).

    build/hot_native/bench_snapshot <engine.so> <hand|schema> <n> <reps>

Initialises an engine with `n` entities, then `reps` times: save a snapshot,
load it into a fresh block, check the loaded state equals the original (count,
frame, every key and draw x), destroy it. Prints one line per rep:

    rep=i bytes=.. save_us=.. load_us=.. equal=1

`hand` is the phase 1 / H2 ABI (engine_snapshot_words + engine_save(addr, buf),
a word array written by hand); `schema` is the H3 ABI (engine_save(addr) ->
buffer, ecs/schema.mojo records). bench_snapshot.py builds both and runs this.
"""

from std.ffi import OwnedDLHandle, RTLD
from std.sys import argv
from std.time import perf_counter_ns
from hotswap import block, free_block, snapshot_bytes


def equal(h: OwnedDLHandle, a: Int, b: Int) raises -> Bool:
    var n = h.get_function[Int]("engine_count")(a)
    if n != h.get_function[Int]("engine_count")(b):
        return False
    if h.get_function[Int]("engine_frame")(a) != h.get_function[Int]("engine_frame")(b):
        return False
    for i in range(n):
        if h.get_function[Int]("engine_key_at")(a, i) != h.get_function[Int]("engine_key_at")(b, i):
            return False
        var xa = h.get_function[Float32]("engine_draw_x")(a, i)
        var xb = h.get_function[Float32]("engine_draw_x")(b, i)
        if xa.to_bits() != xb.to_bits():
            return False
    return True


def main() raises:
    var args = argv()
    var h = OwnedDLHandle(String(args[1]), RTLD.NOW | RTLD.LOCAL)
    var mode = String(args[2])
    var n = atol(String(args[3]))
    var reps = atol(String(args[4]))
    var size = h.get_function[Int]("engine_state_size")()
    var s = block(size)
    h.get_function[NoneType]("engine_init")(s, n)
    for _ in range(7):
        h.get_function[NoneType]("engine_update")(s, Float32(1.0 / 60.0))
    h.get_function[NoneType]("engine_despawn")(s, 0)

    for r in range(reps):
        var t0 = perf_counter_ns()
        var buf: Int
        var nbytes: Int
        if mode == "hand":
            nbytes = 8 * h.get_function[Int]("engine_snapshot_words")(s)
            buf = block(nbytes)
            h.get_function[NoneType]("engine_save")(s, buf)
        else:
            buf = h.get_function[Int]("engine_save")(s)
            nbytes = snapshot_bytes(buf)
        var t1 = perf_counter_ns()
        var s2 = block(size)
        var ok = h.get_function[Int]("engine_load")(s2, buf)
        var t2 = perf_counter_ns()
        if ok != 1:
            raise Error("engine_load returned " + String(ok))
        var same = equal(h, s, s2)
        h.get_function[NoneType]("engine_destroy")(s2)
        free_block(s2)
        free_block(buf)
        print("rep=", r, " bytes=", nbytes, " save_us=", Float64(t1 - t0) / 1000.0,
              " load_us=", Float64(t2 - t1) / 1000.0, " equal=", 1 if same else 0, sep="")
