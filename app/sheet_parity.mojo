"""Native / wasm64 parity probe for event sheets (ludens-engine #24): one sheet, one world, 300 ticks, hashed.

`main` prints the hashes for the native build; `sheet_parity_run` is exported for wasm64."""
from embed.world import EmbedWorld
from game.eventsheet import Sheet
from geometry.vec import Vec3

comptime SHEET = """
event 1
  when tick_mod 20
  do impulse CRATE 0 2 0
  do add kicks 1
event 2 parent 1
  when var kicks >= 3
  do velocity BALL 0.5 0 0
event 3 once
  when below CRATE -1.5
  do add fell 1
  do emit gone
event 4
  when on gone
  do remove CRATE
"""


def run(res: Pointer[UInt64, MutAnyOrigin]) raises:
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    _ = w.add_box(Vec3(0.0, -10.0, 0.0, 0.0), Vec3(20.0, 0.5, 20.0, 0.0), 0.0, True)
    var ball = w.add_sphere(Vec3(0.0, 2.0, 0.0, 0.0), 0.3, 1.0, False)
    var crate = w.add_box(Vec3(3.0, 5.0, 0.0, 0.0), Vec3(0.4, 0.4, 0.4, 0.0), 1.0, False)
    var sheet = Sheet.parse(String(SHEET).replace("BALL", String(ball)).replace("CRATE", String(crate)))
    for _ in range(300):
        sheet.step(w)
        for _ in range(w.ticks_due(1.0 / 60.0)):
            w.physics_tick()
    res[0] = w.hash()
    res[1] = UInt64(sheet.get("kicks"))
    res[2] = UInt64(sheet.get("fell"))
    res[3] = UInt64(sheet.cut)


@export
def sheet_parity_run(out_ptr: UInt64) abi("C") -> Int32:
    try:
        run(Pointer[UInt64, MutAnyOrigin](unsafe_from_address=Int(out_ptr)))
        return 0
    except e:
        print("sheet_parity_run:", e)
        return -1


def main() raises:
    var buf = List[UInt64](length=4, fill=0)
    run(Pointer[UInt64, MutAnyOrigin](unsafe_from_address=Int(buf.unsafe_ptr())))
    print("hash", buf[0], "kicks", buf[1], "fell", buf[2], "cut", buf[3])
