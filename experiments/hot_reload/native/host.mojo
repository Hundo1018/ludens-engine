"""Native hot-reload host: runs ONE (old .so -> new .so, strategy) cell.

    mojo build -I build -I experiments/hot_reload/native experiments/hot_reload/native/host.mojo \
        -o build/hot_native/host
    build/hot_native/host <old.so> <new.so> <strategy> [global]

Protocol (same as the wasm matrix): init(8), 30 frames, despawn 2 and 5,
10 frames, SWAP, 30 frames. Prints `key=value` lines; run_native.py compares
them with its float32 oracle. Label and teardown are printed last because
they are the steps expected to crash under some strategies: the lines already
printed survive a SIGSEGV, and the missing ones tell run_native.py where it died.

Strategies:
  restart   destroy old state, unload old, new state from engine_init
  keep      state block untouched, old .so stays loaded
  close     state block untouched, old .so unloaded
  rebind    `close` + new .so re-points fields that reference static data
  snapshot  old saves -> old destroys -> unload old -> new loads into a fresh block
  auto      rebind if (state size, layout id) match, else snapshot
  samepath  new .so moved onto the OLD path, then loaded by that path
"""

from std.ffi import RTLD
from std.sys import argv
from std.time import perf_counter_ns
from hotswap import CAPACITY, Engine, block, maps_count, owner, rename

comptime PRE = 30
comptime MID = 10
comptime POST = 30


def main() raises:
    var args = argv()
    var old_path = String(args[1])
    var new_path = String(args[2])
    var strategy = String(args[3])
    var flags = RTLD.NOW | (RTLD.GLOBAL if len(args) > 4 and String(args[4]) == "global" else RTLD.LOCAL)

    var old = Engine(old_path, flags)
    var s = block(old.size())
    old.init(s)
    for _ in range(PRE):
        old.update(s)
    old.despawn(s, 2)
    old.despawn(s, 5)
    for _ in range(MID):
        old.update(s)
    print("frame_before=", old.frame(s), sep="")

    var used = strategy
    var retained = List[Engine]()  # old modules kept loaded until exit
    var t0 = perf_counter_ns()
    var cur: Engine
    if strategy == "restart":
        old.destroy(s)
        _ = old^
        cur = Engine(new_path, flags)
        s = block(cur.size())
        cur.init(s)
    elif strategy == "keep":
        cur = Engine(new_path, flags)
        retained.append(old^)
    elif strategy == "close":
        cur = Engine(new_path, flags)
        _ = old^
    elif strategy == "samepath":
        rename(new_path, old_path)
        cur = Engine(old_path, flags)
        retained.append(old^)
    else:
        cur = Engine(new_path, flags)
        if strategy == "auto":
            var same = old.size() == cur.size() and old.layout_id() == cur.layout_id()
            used = "rebind" if same else "snapshot"
        if used == "rebind":
            _ = old^
            cur.rebind(s)
        elif used == "snapshot":
            var buf = block(8 * old.snapshot_words(s))
            old.save(s, buf)
            old.destroy(s)
            _ = old^
            s = block(cur.size())
            if cur.load(s, buf) != 1:
                raise Error("engine_load rejected the snapshot")
        else:
            raise Error("unknown strategy " + strategy)
    var t1 = perf_counter_ns()
    print("used=", used, sep="")
    print("swap_us=", Float64(t1 - t0) / 1000.0, sep="")
    var parts = old_path.split("/")
    print("old_mapped=", maps_count(String(parts[len(parts) - 1])), sep="")

    for _ in range(POST):
        cur.update(s)
    var n = cur.count(s)
    print("count=", n, sep="")
    print("frame=", cur.frame(s), sep="")
    print("color=", cur.color(), sep="")
    var keys = String()
    var xs = String()
    for i in range(n):
        keys += String(cur.key_at(s, i)) + ","
        xs += String(cur.draw_x(s, i).to_bits()) + ","
    print("keys=", keys, sep="")
    print("xbits=", xs, sep="")

    var same = strategy == "samepath"
    print("code_owner=", owner(cur.module_addr(), old_path, new_path, same), sep="")
    print("label_owner=", owner(cur.label_addr(s), old_path, new_path, same), sep="")
    var label = String()
    for i in range(cur.label_len(s)):
        label += chr(cur.label_byte(s, i))
    print("label=", label, sep="")
    cur.destroy(s)
    print("teardown=ok")
    print("retained=", len(retained), sep="")
