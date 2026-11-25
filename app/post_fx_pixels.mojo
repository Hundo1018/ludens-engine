"""Native side of the picture-effects pixel parity (#139): render app/post_fx_frame.mojo with wgpu-native, headless, and
write the raw RGBA bytes of both frames (480 x 270, tightly packed).   post_fx_pixels <look.rgba> <msaa.rgba>"""
from post_fx_frame import PostFxFrame, LookStages, MsaaStages, POST_FX_W, POST_FX_H
from std.sys import argv
from wgpu.device import Device
from app.post import PostEffect
from wgpu.instance import Instance


def _write[F: PostEffect, S: Int](device: Device, path: String) raises:
    var frame = PostFxFrame[F, S](device)
    frame.start(device)
    var polls = 0
    var ptr = frame.poll()
    while ptr == 0:
        polls += 1
        if polls > 100_000_000:
            raise Error("post fx frame capture never completed")
        ptr = frame.poll()
    var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(ptr))
    var pitch = Int(frame.pitch())
    var out = List[UInt8](capacity=Int(POST_FX_W) * Int(POST_FX_H) * 4)
    for y in range(Int(POST_FX_H)):
        for x in range(Int(POST_FX_W) * 4):
            out.append(src[y * pitch + x])
    frame.release()
    with open(path, "w") as f:
        f.write_bytes(out)
    print("wrote", path, len(out), "bytes")


def main() raises:
    var device = Instance().request_adapter().request_device()
    _write[LookStages, 1](device, String(argv()[1]))
    _write[MsaaStages, 4](device, String(argv()[2]))
