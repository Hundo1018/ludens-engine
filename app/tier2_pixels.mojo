"""Native side of the rendering tier 2 pixel parity (#140): render app/tier2_frame.mojo (terrain, decals, trails) with
wgpu-native, headless, and write the raw RGBA bytes (480 x 270, tightly packed, no row padding).   tier2_pixels <out.rgba>"""
from tier2_frame import Tier2Reference, TIER2_FRAME_W, TIER2_FRAME_H
from std.sys import argv
from wgpu.instance import Instance


def main() raises:
    var path = String(argv()[1])
    var device = Instance().request_adapter().request_device()
    var reference = Tier2Reference(device)
    reference.start(device)
    var polls = 0
    var ptr = reference.poll()
    while ptr == 0:
        polls += 1
        if polls > 100_000_000:
            raise Error("tier 2 frame capture never completed")
        ptr = reference.poll()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var pitch = Int(reference.pitch())
    var out = List[UInt8](capacity=Int(TIER2_FRAME_W) * Int(TIER2_FRAME_H) * 4)
    for y in range(Int(TIER2_FRAME_H)):
        for x in range(Int(TIER2_FRAME_W) * 4):
            out.append(src[y * pitch + x])
    reference.release()
    with open(path, "w") as f:
        f.write_bytes(out)
    print("wrote", path, len(out), "bytes")
