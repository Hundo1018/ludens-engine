"""World hand-over between two modules (ludens-core 17.91, ludens-engine #14): the program both sides share.

`xfer_save` builds a world, runs `before` ticks, writes the transfer blob to a host buffer, runs `after` more ticks and
reports the world hash. `xfer_load` starts from an empty world, loads a blob and runs `after` ticks. The native
build (`main`) and the wasm64 builds (`app/xfer_a.mojo`, `app/xfer_b.mojo`) call the same functions, so the schedule
cannot differ."""
from embed.transfer import transfer_load, transfer_save
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3

comptime DT = 1.0 / 60.0


def names() -> List[String]:
    var n = List[String]()
    n.append("gravity_zone")
    return n^


def build() raises -> EmbedWorld:
    var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    var floor = w.add_box(Vec3(0.0, -1.0, 0.0, 0.0), Vec3(20.0, 1.0, 20.0, 0.0), 0.0, True)
    w.set_material(floor, 7)
    for i in range(24):
        var b = w.add_box(Vec3(Real(i % 4) * 1.1 - 1.6, 1.0 + Real(i // 4) * 1.05, Real(i % 3) * 0.2, 0.0), Vec3(0.5, 0.5, 0.5, 0.0), 1.0, False)
        w.set_material(b, UInt32(10 + i))
        w.set_user(b, UInt64(1000 + i))
    _ = w.add_sphere(Vec3(0.3, 9.0, 0.1, 0.0), 0.4, 2.0, False)
    return w^


def run(mut w: EmbedWorld, ticks: Int) raises:
    for _ in range(ticks):
        for _ in range(w.ticks_due(DT)):
            w.physics_tick()


def save_run(before: Int, after: Int) raises -> Tuple[List[UInt8], UInt64]:
    var w = build()
    run(w, before)
    var blob = transfer_save(w, names())
    run(w, after)
    return (blob^, w.hash())


def load_run(blob: List[UInt8], after: Int) raises -> UInt64:
    var w = EmbedWorld(DT, Vec3(0.0, -9.81, 0.0, 0.0))
    transfer_load(w, blob, names())
    run(w, after)
    return w.hash()


def xfer_save_impl(before: Int32, after: Int32, buf: UInt64, cap: UInt64, out_ptr: UInt64) -> Int32:
    """out[0] = hash of the uninterrupted run, out[1] = blob length; the blob is copied to `buf` (0 = ok)."""
    try:
        var r = save_run(Int(before), Int(after))
        var o = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        o[0] = r[1]
        o[1] = UInt64(len(r[0]))
        if UInt64(len(r[0])) > cap:
            return -2
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(buf))
        for i in range(len(r[0])):
            p[i] = r[0][i]
        return 0
    except e:
        print("xfer_save:", e)
        return -1


def xfer_load_impl(buf: UInt64, n: UInt64, after: Int32, out_ptr: UInt64) -> Int32:
    """out[0] = hash after loading the blob at `buf` and running `after` ticks (0 = ok)."""
    try:
        var p = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(buf))
        var blob = List[UInt8](capacity=Int(n))
        for i in range(Int(n)):
            blob.append(p[i])
        var o = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        o[0] = load_run(blob, Int(after))
        return 0
    except e:
        print("xfer_load:", e)
        return -1


def main() raises:
    var r = save_run(60, 120)
    print("blob", len(r[0]), "uninterrupted", r[1], "after swap", load_run(r[0], 120))
