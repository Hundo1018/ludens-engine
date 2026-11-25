# tier: unit
"""The PNG writer platform/png.mojo (issue #146), used by the photo capture. Writes three pictures (1 x 1, a 37 x 23 gradient
with noise, a 256 x 128 picture with flat areas and stripes) from rows with a padded pitch, to build/png/<name>.png with
the RGB bytes expected in <name>.rgb. Checked here: the signature, the IHDR fields, each chunk's CRC-32, the zlib
header and the Adler-32 of a known input. scripts/test_console.py then decodes the files with Pillow and compares every
byte. Standard library only."""
from platform.png import crc32, crc32_table, encode_png
from std.os import makedirs
from std.os.path import exists


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
        print("  [" + ("PASS" if cond else "FAIL") + "]", label)


def be32(d: List[UInt8], at: Int) -> UInt32:
    return (UInt32(d[at]) << 24) | (UInt32(d[at + 1]) << 16) | (UInt32(d[at + 2]) << 8) | UInt32(d[at + 3])


def picture(kind: Int, w: Int, h: Int, pitch: Int) -> List[UInt8]:
    var out = List[UInt8](length=pitch * h, fill=0xEE)  # padding bytes are 0xEE: the writer must not read them
    var seed = UInt32(12345)
    for y in range(h):
        for x in range(w):
            var o = y * pitch + 4 * x
            var r: Int
            var g: Int
            var b: Int
            if kind == 0:
                r = 10
                g = 200
                b = 255
            elif kind == 1:
                seed = seed * 1664525 + 1013904223
                r = (x * 7) % 256
                g = (y * 11) % 256
                b = Int(seed >> 24)
            else:
                var sky = y < h // 2
                r = 90 if sky else (180 if (x // 8) % 2 == 0 else 40)
                g = 140 if sky else 120
                b = 230 if sky else 60
            out[o] = UInt8(r)
            out[o + 1] = UInt8(g)
            out[o + 2] = UInt8(b)
            out[o + 3] = 255
    return out^


def main() raises:
    var c = Check()
    var t = crc32_table()
    var abc = List[UInt8]()
    for ch in "123456789".as_bytes():
        abc.append(ch)
    c.ok(crc32(t, abc, 0, len(abc)) == 0xCBF43926, "CRC-32 of 123456789 is cbf43926")
    if not exists("build/png"):
        makedirs("build/png")
    var names = ["one", "noise", "stripes"]
    var ws = [1, 37, 256]
    var hs = [1, 23, 128]
    for k in range(3):
        var w = ws[k]
        var h = hs[k]
        var pitch = ((4 * w + 255) // 256) * 256
        var px = picture(k, w, h, pitch)
        var png = encode_png(px, w, h, pitch)
        var sig_ok = png[0] == 137 and png[1] == 80 and png[2] == 78 and png[3] == 71
        c.ok(sig_ok, names[k] + ": PNG signature")
        c.ok(be32(png, 16) == UInt32(w) and be32(png, 20) == UInt32(h) and png[24] == 8 and png[25] == 2, names[k] + ": IHDR " + String(w) + " x " + String(h) + ", 8-bit RGB")
        var at = 8
        var chunks = 0
        var crc_ok = True
        var zlib_ok = False
        while at + 12 <= len(png):
            var n = Int(be32(png, at))
            if crc32(t, png, at + 4, at + 8 + n) != be32(png, at + 8 + n):
                crc_ok = False
            if png[at + 4] == 73 and png[at + 5] == 68 and png[at + 6] == 65 and png[at + 7] == 84:  # IDAT
                zlib_ok = png[at + 8] == 0x78 and (Int(png[at + 8]) * 256 + Int(png[at + 9])) % 31 == 0
            at += 12 + n
            chunks += 1
        c.ok(chunks == 3 and at == len(png) and crc_ok, names[k] + ": 3 chunks, every CRC-32 matches")
        c.ok(zlib_ok, names[k] + ": the IDAT starts with a valid zlib header")
        var rgb = List[UInt8]()
        for y in range(h):
            for x in range(w):
                for ch in range(3):
                    rgb.append(px[y * pitch + 4 * x + ch])
        with open("build/png/" + names[k] + ".png", "w") as f:
            f.write_bytes(png)
        with open("build/png/" + names[k] + ".rgb", "w") as f:
            f.write_bytes(rgb)
        print("  ", names[k], w, "x", h, ":", len(png), "bytes PNG,", len(rgb), "bytes RGB")
    var bad = False
    try:
        _ = encode_png(List[UInt8](length=10, fill=0), 4, 4, 16)
    except:
        bad = True
    c.ok(bad, "too few bytes for the size raises")
    print("platform_png:", c.passed, "passed,", c.failed, "failed")
    if c.failed > 0:
        raise Error("platform_png failed")
