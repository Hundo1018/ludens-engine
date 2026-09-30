"""Live host for hot compile: runs the engine at ~60 Hz and swaps in every new
build that dev_native.py publishes, without stopping the loop.

    build/hot_native/live_host <watch_dir> [max_seconds]

`<watch_dir>/latest` holds "<version> <path to libengine.so>"; the watcher
replaces it atomically after each successful build, always with a NEW path
(dlopen of an already-loaded path would return the old library). Each swap
uses `auto` (in place if the layout matches, else snapshot). A build that
fails to load is reported and the old module keeps running.

Crash rollback (H1, after cr.h): before each swap the old module saves a
snapshot of the state, and the old module stays loaded. For the next
PROBATION frames every `engine_update` of the new module runs under
guard.mojo's fault guard. On a fault (or a failed `engine_load`) the host
rebuilds the state from the snapshot with the old module, drops the new one
and keeps running; the state block the new code ran on is leaked, because
destroying it could fault again. After PROBATION clean frames the old module
is unloaded and the snapshot freed (`commit`). The loop ends when
`<watch_dir>/stop` exists or after `max_seconds` (default 600).

Output, one line per event, flushed:
    load  version=1 path=...
    tick  frame=.. count=.. color=..            (every 30 frames)
    swap  version=.. used=inplace|snapshot frame_before=.. frame_after=.. count=.. swap_us=..
          copy_bytes=.. copy_us=..          (the rollback snapshot)
    rollback version=.. at=load|update signal=.. frame=.. count=.. rollback_us=..
             (at=load: signal < 0 is guard.guarded_load's code, e.g. -12 = rename without alias)
    commit version=.. frames=..
    swap_error version=.. error=...
"""

from std.ffi import RTLD
from std.os.path import exists
from std.sys import argv
from std.time import perf_counter_ns, sleep
from hotswap import CAPACITY, Engine, block, free_buffer, free_state, snapshot_bytes
from guard import guard_install, guarded_load, guarded_update

comptime FRAME_S = 1.0 / 60.0
comptime PROBATION = 60  # guarded frames after a swap


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

    guard_install()
    var version = first[0]
    var eng = Engine(first[1], flags)
    var s = block(eng.size())
    eng.init(s)
    eng.despawn(s, 2)  # non-trivial state: a restart would bring 2 and 5 back
    eng.despawn(s, 5)
    print("load version=", version, " path=", first[1], sep="", flush=True)

    # probation: the previous module and its snapshot, kept until commit
    var prev = Optional[Engine](None)
    var snap = 0
    var probation = 0

    var t_start = perf_counter_ns()
    while not exists(stop) and Float64(perf_counter_ns() - t_start) / 1e9 < max_s:
        var sig = 0
        if probation > 0:
            sig = guarded_update(eng, s)
        else:
            eng.update(s)
        if sig != 0:
            var t0 = perf_counter_ns()
            var old = prev.take()
            s = block(old.size())
            if old.load(s, snap) != 1:
                raise Error("rollback: the old module rejected its own snapshot")
            free_buffer(snap)
            eng = old^  # drops the faulted module
            probation = 0
            print("rollback version=", version, " at=update signal=", sig, " frame=", eng.frame(s),
                  " count=", eng.count(s), " rollback_us=", Float64(perf_counter_ns() - t0) / 1000.0,
                  sep="", flush=True)
        elif probation > 0:
            probation -= 1
            if probation == 0:
                _ = prev.take()  # unload the old module
                free_buffer(snap)
                print("commit version=", version, " frames=", PROBATION, sep="", flush=True)
        var frame = eng.frame(s)
        if frame % 30 == 0:
            print("tick frame=", frame, " count=", eng.count(s), " color=", eng.color(), sep="", flush=True)

        var nxt = read_latest(latest)
        if nxt[0] > version and probation == 0:
            var candidate = try_load(nxt[1], flags)
            if candidate:
                var new = candidate.take()
                var frame_before = eng.frame(s)
                var t0 = perf_counter_ns()
                snap = eng.save(s)
                var nbytes = snapshot_bytes(snap)
                var t1 = perf_counter_ns()
                var used = String("inplace")
                var s_new = s
                if eng.size() != new.size() or eng.layout_id() != new.layout_id():
                    used = "snapshot"
                    s_new = block(new.size())
                    var rc = guarded_load(new, s_new, snap)
                    if rc != 0:
                        # the old module and its state are untouched: nothing to restore
                        free_buffer(snap)
                        print("rollback version=", nxt[0], " at=load signal=", rc, " frame=", frame_before,
                              " count=", eng.count(s), " rollback_us=0", sep="", flush=True)
                        version = nxt[0]
                        sleep(FRAME_S)
                        continue
                    eng.destroy(s)
                    free_state(s)
                var t2 = perf_counter_ns()
                prev = eng^
                eng = new^
                s = s_new
                probation = PROBATION
                print("swap version=", nxt[0], " used=", used, " frame_before=", frame_before,
                      " frame_after=", eng.frame(s), " count=", eng.count(s),
                      " swap_us=", Float64(t2 - t1) / 1000.0, " copy_bytes=", nbytes,
                      " copy_us=", Float64(t1 - t0) / 1000.0, sep="", flush=True)
            else:
                print("swap_error version=", nxt[0], " error=load failed", sep="", flush=True)
            version = nxt[0]
        sleep(FRAME_S)
    print("exit frame=", eng.frame(s), sep="", flush=True)
