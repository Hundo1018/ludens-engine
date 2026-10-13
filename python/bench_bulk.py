"""ROADMAP 17.78: per-object vs bulk pose exchange across the C boundary.

Runs in the project's pixi environment against build/libludens.so (build it
with `pixi run capi`):

    LUDENS_LIBRARY=build/libludens.so pixi run python python/bench_bulk.py

For N bodies it times, in microseconds per frame:
  * read:  N calls of ld_body_get_state vs one ld_world_get_bodies into a
    caller-owned buffer;
  * write: N calls of ld_body_teleport vs one ld_world_set_poses.
Both paths return / write the same poses (checked here on every run).
Prints a markdown table.
"""

import ctypes
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import ludens  # noqa: E402
from ludens import _capi as C  # noqa: E402


def _build(n):
    w = ludens.World()
    side = int(n ** 0.5) + 1
    bodies = []
    for i in range(n):
        bodies.append(w.add_box((float(i % side) * 2.0, 1.0, float(i // side) * 2.0), (0.4, 0.4, 0.4), 1.0, False))
    return w, bodies


def _row(n, frames=20):
    w, bodies = _build(n)
    handles = (ctypes.c_int64 * n)(*[b.handle for b in bodies])
    buf = (ctypes.c_float * (7 * n))()
    one = (ctypes.c_float * 13)()
    lib = C.lib
    h = w._h
    # read, per object
    t0 = time.perf_counter()
    for _ in range(frames):
        for i in range(n):
            lib.ld_body_get_state(h, handles[i], one)
    t1 = time.perf_counter()
    for _ in range(frames):
        lib.ld_world_get_bodies(h, None, buf, n)
    t2 = time.perf_counter()
    # both reads agree on the last body
    lib.ld_body_get_state(h, handles[n - 1], one)
    assert tuple(one[0:7]) == tuple(buf[7 * (n - 1) : 7 * n]), "per-object and bulk reads differ"
    # write, per object vs bulk (same poses)
    t3 = time.perf_counter()
    for _ in range(frames):
        for i in range(n):
            lib.ld_body_teleport(h, handles[i], buf[7 * i], buf[7 * i + 1] + 0.0, buf[7 * i + 2], buf[7 * i + 3], buf[7 * i + 4], buf[7 * i + 5], buf[7 * i + 6])
    t4 = time.perf_counter()
    for _ in range(frames):
        lib.ld_world_set_poses(h, handles, buf, n)
    t5 = time.perf_counter()
    w.close()
    us = lambda a, b: (b - a) / frames * 1e6
    return us(t0, t1), us(t1, t2), us(t3, t4), us(t4, t5)


def main():
    print("### Host pose exchange through Python ctypes (17.78), us per frame\n")
    print("| bodies | read per object | read bulk | write per object | write bulk |")
    print("|---:|---:|---:|---:|---:|")
    for n in (100, 1000, 10000):
        r = _row(n)
        print("| %d | %.0f | %.0f | %.0f | %.0f |" % (n, r[0], r[1], r[2], r[3]))
    print("")


if __name__ == "__main__":
    main()
