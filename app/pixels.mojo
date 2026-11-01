"""Native side of the pixel parity: render the reference frame with wgpu-native, headless, and write the raw
RGBA bytes (tightly packed, no row padding).   pixels <out.rgba> [frames]"""
from reference import Reference
from std.sys import argv
from wgpu.instance import Instance

comptime WIDTH: UInt32 = 960
comptime HEIGHT: UInt32 = 540


def main() raises:
    var args = argv()
    var path = String(args[1])
    var frames = Int(args[2]) if len(args) > 2 else 240
    var instance = Instance()
    var device = instance.request_adapter().request_device()
    var reference = Reference(device, WIDTH, HEIGHT)
    reference.start(device, frames)
    var polls = 0
    var ptr = reference.poll()
    while ptr == 0:
        polls += 1
        if polls > 100_000_000:
            raise Error("reference capture never completed")
        ptr = reference.poll()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var pitch = Int(reference.pitch())
    var out = List[UInt8](capacity=Int(WIDTH) * Int(HEIGHT) * 4)
    for y in range(Int(HEIGHT)):
        for x in range(Int(WIDTH) * 4):
            out.append(src[y * pitch + x])
    reference.release()
    with open(path, "w") as f:
        f.write_bytes(out)
    print("wrote", path, len(out), "bytes")
