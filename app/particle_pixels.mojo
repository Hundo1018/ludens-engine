"""Native side of the particle pixel parity (#121): render app/particle_frame.mojo with wgpu-native, headless, and write
the raw RGBA bytes (480 x 270, tightly packed, no row padding).   particle_pixels <out.rgba>"""
from particle_frame import ParticleReference, PARTICLE_FRAME_W, PARTICLE_FRAME_H
from std.sys import argv
from wgpu.instance import Instance


def main() raises:
    var path = String(argv()[1])
    var device = Instance().request_adapter().request_device()
    var reference = ParticleReference(device)
    reference.start(device)
    var polls = 0
    var ptr = reference.poll()
    while ptr == 0:
        polls += 1
        if polls > 100_000_000:
            raise Error("particle frame capture never completed")
        ptr = reference.poll()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var pitch = Int(reference.pitch())
    var out = List[UInt8](capacity=Int(PARTICLE_FRAME_W) * Int(PARTICLE_FRAME_H) * 4)
    for y in range(Int(PARTICLE_FRAME_H)):
        for x in range(Int(PARTICLE_FRAME_W) * 4):
            out.append(src[y * pitch + x])
    reference.release()
    with open(path, "w") as f:
        f.write_bytes(out)
    print("wrote", path, len(out), "bytes")
