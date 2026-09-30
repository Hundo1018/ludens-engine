"""Live host for hot compile: runs the engine at ~60 Hz and swaps in every new
build that dev_native.py publishes, without stopping the loop.

    build/hot_native/live_host <watch_dir> [max_seconds]

`<watch_dir>/latest` holds "<version> <path to libengine.so>"; the watcher
replaces it atomically after each successful build, always with a NEW path
(dlopen of an already-loaded path would return the old library). Each swap
uses `auto` from hotswap.mojo. A build that fails to load is reported and the
old module keeps running; a swap that fails after loading is fatal (the
old state was already handed over). The loop ends when `<watch_dir>/stop` exists or
after `max_seconds` (default 600).

Output, one line per event, flushed:
    load  version=1 path=...
    tick  frame=.. count=.. color=..            (every 30 frames)
    swap  version=.. used=rebind|snapshot frame_before=.. frame_after=.. count=.. swap_us=..
    swap_error version=.. error=...
"""

from std.ffi import RTLD
from std.os.path import exists
from std.sys import argv
from std.time import perf_counter_ns, sleep
from hotswap import CAPACITY, Engine, block, swap_auto

comptime FRAME_S = 1.0 / 60.0


def read_latest(path: String) -> Tuple[Int, String]:
    """(version, so_path) from the `latest` file, (0, "") if absent/partial."""
    try:
        var parts = open(path, "r").read().strip().split(" ")
        if len(parts) == 2:
            return (atol(String(parts[0])), String(parts[1]))
    except:
        pass
    return (0, String(""))


def try_load(path: String, flags: Int) -> Optional[Engine]:
    """Load a build; None if dlopen/dlsym fails. The running module is not
    touched until a candidate has loaded."""
    try:
        return Engine(path, flags)
    except:
        return None


def main() raises:
    var args = argv()
    var dir = String(args[1])
    var max_s = Float64(atol(String(args[2]))) if len(args) > 2 else 600.0
    var latest = dir + "/latest"
    var stop = dir + "/stop"
    var flags = RTLD.NOW | RTLD.LOCAL

    var first = read_latest(latest)
    while first[0] == 0:
        if exists(stop):
            return
        sleep(0.05)
        first = read_latest(latest)

    var version = first[0]
    var eng = Engine(first[1], flags)
    var s = block(eng.size())
    eng.init(s)
    eng.despawn(s, 2)  # non-trivial state: a restart would bring 2 and 5 back
    eng.despawn(s, 5)
    print("load version=", version, " path=", first[1], sep="", flush=True)

    var t_start = perf_counter_ns()
    while not exists(stop) and Float64(perf_counter_ns() - t_start) / 1e9 < max_s:
        eng.update(s)
        var frame = eng.frame(s)
        if frame % 30 == 0:
            print("tick frame=", frame, " count=", eng.count(s), " color=", eng.color(), sep="", flush=True)

        var nxt = read_latest(latest)
        if nxt[0] > version:
            var candidate = try_load(nxt[1], flags)
            if candidate:
                var frame_before = eng.frame(s)
                var t0 = perf_counter_ns()
                var r = swap_auto(eng^, candidate.take(), s)
                var t1 = perf_counter_ns()
                var used = r.used
                s = r.state
                eng = r^.into_engine()
                print("swap version=", nxt[0], " used=", used, " frame_before=", frame_before,
                      " frame_after=", eng.frame(s), " count=", eng.count(s),
                      " swap_us=", Float64(t1 - t0) / 1000.0, sep="", flush=True)
            else:
                print("swap_error version=", nxt[0], " error=load failed", sep="", flush=True)
            version = nxt[0]
        sleep(FRAME_S)
    print("exit frame=", eng.frame(s), sep="", flush=True)
