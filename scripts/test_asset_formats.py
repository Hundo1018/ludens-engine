#!/usr/bin/env python3
"""The asset formats and their converters (scripts/assets/, app/assets.mojo; issue #12) on synthetic inputs: no
downloaded asset is needed.

    pixi run -e wasm test-asset-formats

Builds, under build/asset_fixtures/:
  tiny.glb      two joints (a root under a non-joint parent at y 0.5, a child 1 m above it), a four-vertex strip, two
                animations (the child turns 90 degrees about z over 1 s; a still one), and an embedded 4 x 4 PNG as
                material 0's base colour
  tiny.wav      0.1 s of a 441 Hz sine at 22050 Hz, stereo, 16-bit
  tiny.asf/amc  a root and two bones, two frames
then runs each converter on them (and its --selftest), checks what Python can check, and builds and runs
tests/asset_formats.mojo, which reads tiny.lcharacter and tiny.ltexture with app/assets.mojo."""
import io
import json
import math
import struct
import subprocess
import sys
import wave
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "scripts" / "assets"
OUT = ROOT / "build" / "asset_fixtures"
sys.path.insert(0, str(ASSETS))
sys.path.insert(0, str(ROOT / "scripts"))
import convert_glb  # noqa: E402
import motion_fk  # noqa: E402

results = []


def check(cond, label):
    results.append(bool(cond))
    print(f"  [{'PASS' if cond else 'FAIL'}] {label}")


def run(*args):
    r = subprocess.run([sys.executable, *map(str, args)], cwd=ROOT, capture_output=True, text=True, check=False)
    if r.returncode != 0:
        print(r.stdout + r.stderr)
    return r


def png_4x4() -> bytes:
    img = Image.new("RGBA", (4, 4))
    for y in range(4):
        for x in range(4):
            img.putpixel((x, y), (60 * x, 60 * y, 200, 255))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


def tiny_glb(path: Path, png: bytes):
    """The glTF described in the module docstring. Inverse binds: the root's is the identity, the child's T(0,-1,0)."""
    pos = [0.0, 0.0, 0.0, 0.1, 0.0, 0.0, 0.0, 2.0, 0.0, 0.1, 2.0, 0.0]
    nrm = [0.0, 0.0, 1.0] * 4
    uv = [0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 1.0, 1.0]
    joints = [0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]
    weights = [1.0, 0.0, 0.0, 0.0] * 4
    idx = [0, 1, 2, 1, 3, 2]
    ident = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
    child_ibm = ident[:12] + [0.0, -1.0, 0.0, 1.0]
    s45 = math.sin(math.pi / 4)
    times = [0.0, 1.0]
    rots = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, s45, s45]
    still = [0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
    parts = [  # (bytes, accessor fields)
        (struct.pack("<12f", *pos), dict(componentType=5126, count=4, type="VEC3", min=[0, 0, 0], max=[0.1, 2, 0])),
        (struct.pack("<12f", *nrm), dict(componentType=5126, count=4, type="VEC3")),
        (struct.pack("<8f", *uv), dict(componentType=5126, count=4, type="VEC2")),
        (struct.pack("<16H", *joints), dict(componentType=5123, count=4, type="VEC4")),
        (struct.pack("<16f", *weights), dict(componentType=5126, count=4, type="VEC4")),
        (struct.pack("<6H", *idx), dict(componentType=5123, count=6, type="SCALAR")),
        (struct.pack("<32f", *(ident + child_ibm)), dict(componentType=5126, count=2, type="MAT4")),
        (struct.pack("<2f", *times), dict(componentType=5126, count=2, type="SCALAR", min=[0.0], max=[1.0])),
        (struct.pack("<8f", *rots), dict(componentType=5126, count=2, type="VEC4")),
        (struct.pack("<8f", *still), dict(componentType=5126, count=2, type="VEC4")),
    ]
    blob = bytearray()
    views, accessors = [], []
    for i, (data, acc) in enumerate(parts):
        while len(blob) % 4:
            blob.append(0)
        views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)})
        accessors.append({"bufferView": i, **acc})
        blob += data
    while len(blob) % 4:
        blob.append(0)
    views.append({"buffer": 0, "byteOffset": len(blob), "byteLength": len(png)})
    blob += png
    while len(blob) % 4:
        blob.append(0)
    doc = {
        "asset": {"version": "2.0"},
        "scene": 0,
        "scenes": [{"nodes": [0, 3]}],
        "nodes": [
            {"name": "Armature", "translation": [0.0, 0.5, 0.0], "children": [1]},
            {"name": "root", "children": [2]},
            {"name": "child", "translation": [0.0, 1.0, 0.0]},
            {"name": "mesh", "mesh": 0, "skin": 0},
        ],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2, "JOINTS_0": 3,
                                                   "WEIGHTS_0": 4}, "indices": 5, "material": 0}]}],
        "skins": [{"joints": [1, 2], "inverseBindMatrices": 6}],
        "animations": [
            {"name": "turn", "samplers": [{"input": 7, "output": 8, "interpolation": "LINEAR"}],
             "channels": [{"sampler": 0, "target": {"node": 2, "path": "rotation"}}]},
            {"name": "still", "samplers": [{"input": 7, "output": 9, "interpolation": "LINEAR"}],
             "channels": [{"sampler": 0, "target": {"node": 2, "path": "rotation"}}]},
        ],
        "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        "textures": [{"source": 0}],
        "images": [{"bufferView": len(parts), "mimeType": "image/png"}],
        "buffers": [{"byteLength": len(blob)}],
        "bufferViews": views,
        "accessors": accessors,
    }
    js = json.dumps(doc).encode("utf-8")
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(blob)
    path.write_bytes(struct.pack("<III", 0x46546C67, 2, total) + struct.pack("<II", len(js), 0x4E4F534A) + js
                     + struct.pack("<II", len(blob), 0x004E4942) + bytes(blob))


def tiny_wav(path: Path):
    rate, n = 22050, 2205
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for i in range(n):
            v = int(round(16000 * math.sin(2 * math.pi * 441 * i / rate)))
            frames += struct.pack("<hh", v, v)
        w.writeframes(bytes(frames))


ASF = """:version 1.10
:name tiny
:units
  mass 1.0
  length 1.0
  angle deg
:documentation
  two bones on a root
:root
   order TX TY TZ RX RY RZ
   axis XYZ
   position 0 0 0
   orientation 0 0 0
:bonedata
  begin
     id 1
     name a
     direction 0 1 0
     length 1
     axis 0 0 0  XYZ
    dof rz
  end
  begin
     id 2
     name b
     direction 1 0 0
     length 2
     axis 0 0 0  XYZ
    dof rx ry rz
  end
:hierarchy
  begin
    root a
    a b
  end
"""

AMC = """#!OML:ASF tiny.asf
:FULLY-SPECIFIED
:DEGREES
1
root 0 0 0 0 0 0
a 0
b 0 0 0
2
root 1 0 0 0 0 0
a 90
b 0 0 0
"""


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    png = png_4x4()
    glb = OUT / "tiny.glb"
    tiny_glb(glb, png)

    print("convert_glb")
    r = run(ASSETS / "convert_glb.py", glb, OUT / "tiny.lcharacter")
    check(r.returncode == 0, "converts the synthetic glb")
    header, blobs, offsets = convert_glb.read_back(OUT / "tiny.lcharacter")
    check(header["vertices"] == 4 and header["indices"] == 6 and header["joints"] == 2 and header["fps"] == 30,
          "4 vertices, 6 indices, 2 joints, 30 fps")
    check([c["frames"] for c in header["clips"]] == [31, 31] and [c["kind"] for c in header["clips"]] == [100, 101],
          "two clips of 31 frames (1 s at 30 fps, both ends), kinds 100 and 101")
    check(run(ASSETS / "convert_glb.py", "--selftest", glb).returncode == 0,
          "--selftest passes (rest-pose skinning reproduces root_transform * p)")

    print("extract_glb_texture + convert_texture")
    r = run(ASSETS / "extract_glb_texture.py", glb, 0, OUT / "tiny_base.png")
    check(r.returncode == 0 and (OUT / "tiny_base.png").read_bytes() == png, "material 0's image comes out byte for byte")
    r = run(ASSETS / "convert_texture.py", OUT / "tiny_base.png", OUT / "tiny.ltexture", "--size", 8)
    check(r.returncode == 0, "converts it at 8 x 8")
    t = (OUT / "tiny.ltexture").read_bytes()
    check(t[:4] == b"LTEX" and struct.unpack_from("<IIII", t, 4) == (1, 8, 8, 4), "LTEX v1, 8 x 8, 4 levels (8, 4, 2, 1)")
    check(run(ASSETS / "convert_texture.py", "--selftest", OUT / "tiny_base.png", "--size", 8).returncode == 0,
          "--selftest passes")

    print("convert_wav")
    wav = OUT / "tiny.wav"
    tiny_wav(wav)
    r = run(ASSETS / "convert_wav.py", wav, OUT / "tiny.lsound")
    check(r.returncode == 0, "converts 22050 Hz stereo")
    s = (OUT / "tiny.lsound").read_bytes()
    (hlen,) = struct.unpack_from("<I", s, 8)
    h = json.loads(s[12:12 + hlen])
    check(s[:4] == b"LSND" and h["rate"] == 48000 and h["channels"] == 1 and h["frames"] == 4800,
          f"LSND, 48000 Hz mono, 4800 frames ({h['frames']})")
    check(len(s) - 12 - hlen == 2 * h["frames"], "the samples follow the header, two bytes each")
    check(run(ASSETS / "convert_wav.py", "--selftest", wav).returncode == 0, "--selftest passes")

    print("motion_fk")
    (OUT / "tiny.asf").write_text(ASF)
    (OUT / "tiny.amc").write_text(AMC)
    asf = motion_fk.parse_asf(OUT / "tiny.asf")
    frames = motion_fk.parse_amc(OUT / "tiny.amc", set(asf["bones"]) | {"root"})
    check(asf["order"] == ["a", "b"] and asf["bones"]["b"]["parent"] == "a" and len(frames) == 2,
          "two bones in id order, b under a, two frames")
    p0 = motion_fk.positions(asf, frames[0])
    p1 = motion_fk.positions(asf, frames[1])
    near = lambda u, v: max(abs(x - y) for x, y in zip(u, v, strict=True)) < 1e-9  # noqa: E731
    check(near(p0["a"], [0, 1, 0]) and near(p0["b"], [2, 1, 0]), "frame 1: a ends at (0, 1, 0), b at (2, 1, 0)")
    check(near(p1["a"], [0, 0, 0]) and near(p1["b"], [0, 2, 0]),
          "frame 2 (root moved +1 x, a turned 90 deg about z): a ends at (0, 0, 0), b at (0, 2, 0)")
    motion_fk.write_v2(OUT / "tiny.lmotion", asf, frames, 120)
    mh, rest, values = motion_fk.read_v2(OUT / "tiny.lmotion")
    check(mh["frames"] == 2 and len(rest) == 14 and len(values) == 2 * (6 + 1 + 3) and values[6 + 10] == 90.0,
          "LMOT v2 round trip: 2 frames, 7 rest floats per bone, 6 + 1 + 3 values per frame")

    print("app/assets.mojo")
    import build_core
    exe = build_core.build_native("tests/asset_formats.mojo", ROOT / "build/asset_formats", asserts=True, engine=True)
    check(subprocess.run([str(exe)], cwd=ROOT, check=False).returncode == 0, "tests/asset_formats.mojo passes")

    print(f"asset formats: {sum(results)} / {len(results)} checks")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
