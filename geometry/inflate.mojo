"""DEFLATE (RFC 1951) and zlib (RFC 1950) decoding (ROADMAP 17.63).

`inflate(d)` decodes a raw DEFLATE stream: stored, fixed-Huffman and
dynamic-Huffman blocks. `zlib_inflate(d)` checks the two-byte zlib header and
the Adler-32 trailer around one. The Huffman decoding follows zlib's puff.c:
a code is a count per code length plus the symbols sorted by code, read one
bit at a time. Raises on a truncated stream, a reserved block type, an
over-subscribed code, an incomplete code-length code, a distance that reaches
before the output start, a stored-length mismatch, a bad zlib header, a bad
Adler-32, and output longer than `max_out` (so a hostile stream cannot
allocate without limit).
"""


comptime _MAX_BITS = 15


struct _Huff(Movable):
    var count: List[Int]  # codes of each length 0..15
    var symbol: List[Int]  # symbols sorted by (length, value)
    var left: Int  # unused code space after construction; 0 = complete

    def __init__(out self, lengths: List[Int], start: Int, n: Int) raises:
        self.count = List[Int](length=_MAX_BITS + 1, fill=0)
        self.symbol = List[Int](length=n, fill=0)
        for s in range(n):
            self.count[lengths[start + s]] += 1
        var left = 1
        for ln in range(1, _MAX_BITS + 1):
            left <<= 1
            left -= self.count[ln]
            if left < 0:
                raise Error("inflate: over-subscribed Huffman code")
        self.left = left
        var offs = List[Int](length=_MAX_BITS + 1, fill=0)
        for ln in range(1, _MAX_BITS):
            offs[ln + 1] = offs[ln] + self.count[ln]
        for s in range(n):
            var ln = lengths[start + s]
            if ln != 0:
                self.symbol[offs[ln]] = s
                offs[ln] += 1


struct _Inflater(Movable):
    var pos: Int  # next unread byte of the input
    var bitbuf: Int  # bits read from the input, least significant first
    var bitcnt: Int  # valid bits in bitbuf (always < 8 between calls)
    var out: List[UInt8]
    var max_out: Int
    var lbase: List[Int]
    var lext: List[Int]
    var dbase: List[Int]
    var dext: List[Int]

    def __init__(out self, start: Int, max_out: Int):
        self.pos = start
        self.bitbuf = 0
        self.bitcnt = 0
        self.out = List[UInt8]()
        self.max_out = max_out
        self.lbase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
        self.lext = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
        self.dbase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
        self.dext = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    def bits(mut self, d: List[UInt8], need: Int) raises -> Int:
        while self.bitcnt < need:
            if self.pos >= len(d):
                raise Error("inflate: truncated stream")
            self.bitbuf |= Int(d[self.pos]) << self.bitcnt
            self.pos += 1
            self.bitcnt += 8
        var v = self.bitbuf & ((1 << need) - 1)
        self.bitbuf >>= need
        self.bitcnt -= need
        return v

    def put(mut self, b: UInt8) raises:
        if len(self.out) >= self.max_out:
            raise Error("inflate: output exceeds max_out")
        self.out.append(b)

    def decode(mut self, d: List[UInt8], h: _Huff) raises -> Int:
        var code = 0
        var first = 0
        var index = 0
        for ln in range(1, _MAX_BITS + 1):
            code |= self.bits(d, 1)
            var cnt = h.count[ln]
            if code - first < cnt:
                return h.symbol[index + (code - first)]
            index += cnt
            first += cnt
            first <<= 1
            code <<= 1
        raise Error("inflate: invalid Huffman code")

    def codes(mut self, d: List[UInt8], lit: _Huff, dist: _Huff) raises:
        while True:
            var sym = self.decode(d, lit)
            if sym < 256:
                self.put(UInt8(sym))
            elif sym == 256:
                return
            else:
                var s = sym - 257
                if s >= 29:
                    raise Error("inflate: invalid length code")
                var extra = self.bits(d, self.lext[s])
                var length = self.lbase[s] + extra
                var ds = self.decode(d, dist)
                if ds >= 30:
                    raise Error("inflate: invalid distance code")
                var dextra = self.bits(d, self.dext[ds])
                var distance = self.dbase[ds] + dextra
                if distance > len(self.out):
                    raise Error("inflate: distance reaches before the output start")
                for _ in range(length):
                    self.put(self.out[len(self.out) - distance])

    def stored(mut self, d: List[UInt8]) raises:
        self.bitbuf = 0
        self.bitcnt = 0
        if self.pos + 4 > len(d):
            raise Error("inflate: truncated stored block")
        var n = Int(d[self.pos]) | (Int(d[self.pos + 1]) << 8)
        var nn = Int(d[self.pos + 2]) | (Int(d[self.pos + 3]) << 8)
        if n ^ nn != 0xFFFF:
            raise Error("inflate: stored block length check failed")
        self.pos += 4
        if self.pos + n > len(d):
            raise Error("inflate: truncated stored block")
        for i in range(n):
            self.put(d[self.pos + i])
        self.pos += n

    def fixed(mut self, d: List[UInt8]) raises:
        var lengths = List[Int](length=288, fill=8)
        for s in range(144, 256):
            lengths[s] = 9
        for s in range(256, 280):
            lengths[s] = 7
        var dlengths = List[Int](length=30, fill=5)
        var lit = _Huff(lengths, 0, 288)
        var dist = _Huff(dlengths, 0, 30)
        self.codes(d, lit, dist)

    def dynamic(mut self, d: List[UInt8]) raises:
        var nlen = self.bits(d, 5) + 257
        var ndist = self.bits(d, 5) + 1
        var ncode = self.bits(d, 4) + 4
        if nlen > 286 or ndist > 30:
            raise Error("inflate: too many length or distance codes")
        var order: List[Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var clen = List[Int](length=19, fill=0)
        for i in range(ncode):
            clen[order[i]] = self.bits(d, 3)
        var cl = _Huff(clen, 0, 19)
        if cl.left != 0:
            raise Error("inflate: incomplete code-length code")
        var total = nlen + ndist
        var ls = List[Int](length=total, fill=0)
        var index = 0
        while index < total:
            var sym = self.decode(d, cl)
            if sym < 16:
                ls[index] = sym
                index += 1
            else:
                var val = 0
                var rep: Int
                match sym:
                    case 16:
                        if index == 0:
                            raise Error("inflate: repeat with no previous length")
                        val = ls[index - 1]
                        rep = 3 + self.bits(d, 2)
                    case 17:
                        rep = 3 + self.bits(d, 3)
                    case _:
                        rep = 11 + self.bits(d, 7)
                if index + rep > total:
                    raise Error("inflate: code lengths overrun")
                for _ in range(rep):
                    ls[index] = val
                    index += 1
        if ls[256] == 0:
            raise Error("inflate: no end-of-block code")
        var lit = _Huff(ls, 0, nlen)
        var dist = _Huff(ls, nlen, ndist)
        self.codes(d, lit, dist)


def _inflate_blocks(d: List[UInt8], start: Int, max_out: Int) raises -> _Inflater:
    var st = _Inflater(start, max_out)
    var last = 0
    while last == 0:
        last = st.bits(d, 1)
        var typ = st.bits(d, 2)
        match typ:
            case 0:
                st.stored(d)
            case 1:
                st.fixed(d)
            case 2:
                st.dynamic(d)
            case _:
                raise Error("inflate: reserved block type")
    return st^


def inflate(d: List[UInt8], max_out: Int = 1 << 30) raises -> List[UInt8]:
    """Decode a raw DEFLATE stream (RFC 1951) from its first byte."""
    var st = _inflate_blocks(d, 0, max_out)
    return st.out.copy()


def _adler32(d: List[UInt8]) -> Int:
    var a = 1
    var b = 0
    for x in d:
        a = (a + Int(x)) % 65521
        b = (b + a) % 65521
    return (b << 16) | a


def zlib_inflate(d: List[UInt8], max_out: Int = 1 << 30) raises -> List[UInt8]:
    """Decode a zlib stream (RFC 1950): header, DEFLATE data, Adler-32 trailer.
    Preset dictionaries are refused."""
    if len(d) < 2:
        raise Error("zlib: stream shorter than the header")
    var cmf = Int(d[0])
    var flg = Int(d[1])
    if (cmf * 256 + flg) % 31 != 0:
        raise Error("zlib: header check failed")
    if cmf & 0x0F != 8 or (cmf >> 4) > 7:
        raise Error("zlib: not a DEFLATE stream with a valid window")
    if flg & 0x20 != 0:
        raise Error("zlib: preset dictionaries are not supported")
    var st = _inflate_blocks(d, 2, max_out)
    if st.pos + 4 > len(d):
        raise Error("zlib: missing Adler-32 trailer")
    var want = (Int(d[st.pos]) << 24) | (Int(d[st.pos + 1]) << 16) | (Int(d[st.pos + 2]) << 8) | Int(d[st.pos + 3])
    if _adler32(st.out) != want:
        raise Error("zlib: Adler-32 mismatch")
    return st.out.copy()
