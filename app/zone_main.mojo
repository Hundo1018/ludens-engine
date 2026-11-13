"""A zone of the world as its own wasm module: one simulation, stepped in a Web Worker beside the app.

The app's module draws and reads input on the main thread; each zone module owns one `EmbedWorld` and steps it at a
fixed 60 Hz in a worker of its own, so zones run in parallel without shared memory (a static host such as GitHub Pages
has no SharedArrayBuffer). What crosses to the app each tick is the item array below, copied out by the worker
(shell/web/zone_worker.ts) and posted as a transferable buffer.

Item layout, ITEM_FLOATS f32 per body: x, y, z, qx, qy, qz, qw, kind (0 box, 1 sphere).

This first version holds a field of boxes dropped on a floor: enough to measure what a second and third module cost
(scripts/multi_wasm_probe.py). The zones of the Frontier sample replace `_build`."""
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3
from std.memory import alloc, Layout

comptime ITEM_FLOATS: Int = 8
comptime DT: Real = 1.0 / 60.0


struct Zone(Movable):
    var world: EmbedWorld
    var handles: List[Int64]
    var items: List[Float32]
    var ticks: UInt64

    def __init__(out self, n: Int, seed: Int) raises:
        self.world = EmbedWorld(Float64(DT), Vec3(0.0, -9.81, 0.0, 0.0))
        _ = self.world.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(400.0, 1.0, 400.0, 0.0), 0.0, True)
        var side = 1
        while side * side < n:
            side += 1
        var half = Real(side) * 0.6
        self.handles = List[Int64]()
        for i in range(n):
            var x = Real(i % side) * 1.2 - half
            var z = Real(i // side) * 1.2 - half
            # Heights differ by body and by seed, so the boxes land over the first second and two zones are not copies.
            var y = Real(0.6) + Real((i * 7 + seed * 13) % 11) * 0.25
            self.handles.append(self.world.add_box(Vec3(x, y, z, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False))
        self.items = List[Float32](length=ITEM_FLOATS * n, fill=0.0)
        self.ticks = 0

    def tick(mut self) raises:
        self.world.physics_tick()
        self.ticks += 1
        for i in range(len(self.handles)):
            var st = self.world.state(self.handles[i])
            var o = ITEM_FLOATS * i
            self.items[o] = Float32(st.pos[0])
            self.items[o + 1] = Float32(st.pos[1])
            self.items[o + 2] = Float32(st.pos[2])
            self.items[o + 3] = Float32(st.rot.x)
            self.items[o + 4] = Float32(st.rot.y)
            self.items[o + 5] = Float32(st.rot.z)
            self.items[o + 6] = Float32(st.rot.w)
            self.items[o + 7] = 0.0


def _zone(handle: UInt64) -> Pointer[Zone, MutUntrackedOrigin]:
    return Pointer[Zone, MutUntrackedOrigin](unsafe_from_address=Int(handle))


@export
def app_zone_create(n: Int32, seed: Int32) abi("C") -> UInt64:
    """A zone with n bodies. 0 on failure."""
    try:
        var allocation = alloc(Layout[Zone](count=1))
        var p: Pointer[Zone, MutUntrackedOrigin] = allocation^.unsafe_leak()
        p.unsafe_write(Zone(Int(n), Int(seed)))
        return UInt64(Int(p))
    except e:
        print("app_zone_create:", e)
        return 0


@export
def app_zone_tick(zone: UInt64, count: Int32) abi("C") -> Int32:
    """Step `count` fixed ticks and refresh the item array. 0 = ok."""
    try:
        for _ in range(Int(count)):
            _zone(zone)[].tick()
        return 0
    except e:
        print("app_zone_tick:", e)
        return -1


@export
def app_zone_items_ptr(zone: UInt64) abi("C") -> UInt64:
    """Address of the item array (f32). Valid until the next call into this module."""
    return UInt64(Int(_zone(zone)[].items.unsafe_ptr()))


@export
def app_zone_items_len(zone: UInt64) abi("C") -> Int32:
    """Number of f32 in the item array (ITEM_FLOATS per body)."""
    return Int32(len(_zone(zone)[].items))


@export
def app_zone_ticks(zone: UInt64) abi("C") -> UInt64:
    return _zone(zone)[].ticks


@export
def app_zone_hash(zone: UInt64) abi("C") -> UInt64:
    """The world's state hash: equal on every target and in every worker for the same (n, seed, ticks)."""
    return _zone(zone)[].world.hash()


def main() raises:
    # Native reference for scripts/multi_wasm_probe.py: the hashes a worker must reproduce.
    for seed in range(4):
        var z = Zone(1000, seed)
        for _ in range(120):
            z.tick()
        print("zone n 1000 seed", seed, "ticks 120 hash", z.world.hash())
