"""A PNG writer for the photo mode's capture (game/photo_camera.mojo, docs/photo-mode.md, issue #146).

`encode_png(rgba, width, height, pitch)` takes 8-bit RGBA rows (`pitch` bytes apart, so a GPU readback with padded rows
is passed as is) and returns a complete PNG file: signature, IHDR (8-bit RGB, colour type 2: the alpha of a rendered
frame is not part of the picture), one IDAT and IEND.

The IDAT is a zlib stream of deflate blocks with fixed Huffman codes and one kind of match: a run of the byte four
before (one pixel to the left after the Sub filter, distance 3 for RGB). Every row uses filter 1 (Sub), so a flat sky or
floor becomes a run of zero bytes. That is not what zlib's level 6 reaches, but it is about 60 lines, needs nothing
beyond the standard library and is exact; the test decodes it with Pillow (scripts/test_photo.py).

Checksums: CRC-32 (ISO 3309, as in PNG) per chunk, Adler-32 over the uncompressed scanlines. Standard library only."""

def crc32_table() -> List[UInt32]:
    var t = List[UInt32](capacity=256)
    for n in range(256):
        var c = UInt32(n)
        for _ in range(8):
            if c & 1:
                c = UInt32(0xEDB88320) ^ (c >> 1)
            else:
                c = c >> 1
        t.append(c)
    return t^


def crc32(table: List[UInt32], data: List[UInt8], start: Int, end: Int) -> UInt32:
    var c = UInt32(0xFFFFFFFF)
    for i in range(start, end):
        c = table[Int((c ^ UInt32(data[i])) & 0xFF)] ^ (c >> 8)
    return c ^ UInt32(0xFFFFFFFF)


def _put_be32(mut out: List[UInt8], v: UInt32):
    out.append(UInt8((v >> 24) & 0xFF))
    out.append(UInt8((v >> 16) & 0xFF))
    out.append(UInt8((v >> 8) & 0xFF))
    out.append(UInt8(v & 0xFF))


struct _Bits(Movable):
    """Deflate's bit order: values go in least significant bit first; Huffman codes are reversed before they are put."""
    var out: List[UInt8]
    var acc: UInt64
    var n: Int

    def __init__(out self, capacity: Int):
        self.out = List[UInt8](capacity=capacity)
        self.acc = 0
        self.n = 0

    def put(mut self, value: UInt32, bits: Int):
        self.acc |= UInt64(value) << UInt64(self.n)
        self.n += bits
        while self.n >= 8:
            self.out.append(UInt8(self.acc & 0xFF))
            self.acc >>= 8
            self.n -= 8

    def put_code(mut self, code: UInt32, bits: Int):
        var r = UInt32(0)
        for i in range(bits):
            r = (r << 1) | ((code >> UInt32(i)) & 1)
        self.put(r, bits)

    def flush(mut self):
        if self.n > 0:
            self.out.append(UInt8(self.acc & 0xFF))
            self.acc = 0
            self.n = 0


def _lit(mut b: _Bits, v: Int):
    """A literal or length symbol (0..287) in the fixed Huffman code of RFC 1951 section 3.2.6."""
    if v < 144:
        b.put_code(UInt32(0x30 + v), 8)
    elif v < 256:
        b.put_code(UInt32(0x190 + v - 144), 9)
    elif v < 280:
        b.put_code(UInt32(v - 256), 7)
    else:
        b.put_code(UInt32(0xC0 + v - 280), 8)


def _match(mut b: _Bits, length: Int, dist_code: Int):
    """A match of 3..258 bytes; `dist_code` is a distance code whose base distance needs no extra bits (0..3: 1..4).
    Length codes (RFC 1951 3.2.5): 3..10 are symbols 257..264 with no extra bits; 258 is 285; in between, with
    L = length - 3 and e = floor(log2 L) - 2, the symbol is 257 + 4 e + 4 + (L >> e & 3) with e extra bits."""
    if length == 258:
        _lit(b, 285)
    elif length <= 10:
        _lit(b, 257 + length - 3)
    else:
        var l = length - 3
        var top = 0
        while (l >> (top + 1)) > 0:
            top += 1
        var e = top - 2
        var sel = (l >> e) & 3
        _lit(b, 257 + 4 * e + 4 + sel)
        b.put(UInt32(l - ((4 + sel) << e)), e)
    b.put_code(UInt32(dist_code), 5)


def encode_png(rgba: List[UInt8], width: Int, height: Int, pitch: Int) raises -> List[UInt8]:
    """A PNG of `width` x `height` from RGBA rows `pitch` bytes apart (pitch >= 4 * width); alpha is dropped."""
    if width < 1 or height < 1 or pitch < 4 * width or len(rgba) < pitch * (height - 1) + 4 * width:
        raise Error("png: " + String(width) + " x " + String(height) + " at pitch " + String(pitch) + " needs more than " + String(len(rgba)) + " bytes")
    # The scanlines: a filter byte (1, Sub) and then each byte minus the one 3 before it in the row (RGB).
    var row = 1 + 3 * width
    var raw = List[UInt8](capacity=row * height)
    for y in range(height):
        raw.append(1)
        var o = y * pitch
        for x in range(width):
            for c in range(3):
                var v = rgba[o + 4 * x + c]
                var left = rgba[o + 4 * (x - 1) + c] if x > 0 else UInt8(0)
                raw.append(v - left)
    # Deflate: one final block (BFINAL 1, BTYPE 01 fixed). A run of the byte 3 back, when at least 3 long, is a match
    # of distance 3 (code 2); everything else is a literal.
    var b = _Bits(len(raw) // 4 + 64)
    b.put(1, 1)
    b.put(1, 2)
    var i = 0
    var n = len(raw)
    while i < n:
        var run = 0
        if i >= 3:
            while i + run < n and run < 258 and raw[i + run] == raw[i + run - 3]:
                run += 1
        if run >= 3:
            _match(b, run, 2)
            i += run
        else:
            _lit(b, Int(raw[i]))
            i += 1
    _lit(b, 256)
    b.flush()
    var a = UInt32(1)
    var s = UInt32(0)
    for k in range(n):
        a = (a + UInt32(raw[k])) % 65521
        s = (s + a) % 65521
    var z = List[UInt8](capacity=len(b.out) + 6)
    z.append(0x78)  # CMF: deflate, 32 KiB window
    z.append(0x01)  # FLG: no dictionary, fastest; (0x78 * 256 + 0x01) % 31 == 0
    z.extend(b.out.copy())
    _put_be32(z, (s << 16) | a)

    var table = crc32_table()
    var out = List[UInt8](capacity=len(z) + 64)
    for v in [137, 80, 78, 71, 13, 10, 26, 10]:  # the PNG signature
        out.append(UInt8(v))
    var ihdr = List[UInt8]()
    _put_be32(ihdr, UInt32(width))
    _put_be32(ihdr, UInt32(height))
    ihdr.append(8)  # bit depth
    ihdr.append(2)  # colour type: RGB
    ihdr.append(0)  # compression: deflate
    ihdr.append(0)  # filter method 0
    ihdr.append(0)  # no interlace
    _chunk(out, table, "IHDR", ihdr)
    _chunk(out, table, "IDAT", z)
    _chunk(out, table, "IEND", List[UInt8]())
    return out^


def _chunk(mut out: List[UInt8], table: List[UInt32], kind: String, data: List[UInt8]):
    _put_be32(out, UInt32(len(data)))
    var start = len(out)
    for c in kind.as_bytes():
        out.append(c)
    out.extend(data.copy())
    _put_be32(out, crc32(table, out, start, len(out)))
