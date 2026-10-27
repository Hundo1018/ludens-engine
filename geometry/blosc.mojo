"""Blosc 1 chunk decoding for `.vdb` value streams (ROADMAP 17.63).

OpenVDB compresses a value stream with c-blosc 1: a 16-byte header (format
version 2, the lz77 version, flags, typesize, nbytes, blocksize, cbytes, all
little-endian), then one int32 start per block, then each block as one
int32-size-prefixed stream per typesize split (one stream with the don't-split
flag). A split stored raw has size equal to its length; otherwise it is an LZ4
block. Byte shuffle is applied per block when the shuffle flag is set. Only
the memcpy and LZ4 paths are decoded: those are the paths OpenVDB writes with
its default compressor. Raises on a bad or truncated chunk, a compressor other
than LZ4, and a size that does not match the expected count.
"""


def _le32(c: List[UInt8], at: Int) raises -> Int:
    if at < 0 or at + 4 > len(c):
        raise Error("blosc: truncated chunk")
    return Int(c[at]) | (Int(c[at + 1]) << 8) | (Int(c[at + 2]) << 16) | (Int(c[at + 3]) << 24)


def _lz4_len(src: List[UInt8], mut at: Int, base: Int) raises -> Int:
    """An LZ4 length: `base` (already 15) plus the 255-run extension bytes."""
    var v = base
    while True:
        if at >= len(src):
            raise Error("blosc: truncated LZ4 length")
        var b = Int(src[at])
        at += 1
        v += b
        if b != 255:
            return v


def lz4_decode(src: List[UInt8], n_out: Int) raises -> List[UInt8]:
    """One LZ4 block (no frame header) decoded to exactly `n_out` bytes. A
    match may overlap its own output (offset < length), so it copies byte by
    byte."""
    var out = List[UInt8]()
    var at = 0
    var n = len(src)
    while at < n:
        var token = Int(src[at])
        at += 1
        var lit = token >> 4
        if lit == 15:
            lit = _lz4_len(src, at, 15)
        if at + lit > n:
            raise Error("blosc: truncated LZ4 literals")
        for k in range(lit):
            out.append(src[at + k])
        at += lit
        if at >= n:
            break  # the last sequence has literals only
        if at + 2 > n:
            raise Error("blosc: truncated LZ4 offset")
        var off = Int(src[at]) | (Int(src[at + 1]) << 8)
        at += 2
        var ml = token & 15
        if ml == 15:
            ml = _lz4_len(src, at, 15)
        ml += 4
        if off == 0 or off > len(out):
            raise Error("blosc: LZ4 offset reaches before the output")
        if len(out) + ml > n_out:
            raise Error("blosc: LZ4 output longer than the chunk says")
        var start = len(out) - off
        for k in range(ml):
            var b = out[start + k]
            out.append(b)
    if len(out) != n_out:
        raise Error("blosc: LZ4 output is not the chunk's size")
    return out^


def blosc_decode(c: List[UInt8], n_out: Int) raises -> List[UInt8]:
    """The `n_out` bytes of one blosc 1 chunk `c`, which must be exactly the
    chunk (its cbytes header field equals `len(c)`)."""
    if len(c) < 16:
        raise Error("blosc: truncated header")
    if c[0] != 2:
        raise Error("blosc: unsupported format version")
    var flags = Int(c[2])
    var ts = Int(c[3])
    var nb = _le32(c, 4)
    var bs = _le32(c, 8)
    var cb = _le32(c, 12)
    if cb != len(c) or nb != n_out:
        raise Error("blosc: chunk size or count does not match the stream")
    if nb == 0:
        return List[UInt8]()
    if flags & 2 != 0:  # memcpyed: the data follows the header raw
        if 16 + nb > len(c):
            raise Error("blosc: truncated memcpyed chunk")
        var raw = List[UInt8](length=nb, fill=0)
        for k in range(nb):
            raw[k] = c[16 + k]
        return raw^
    if flags >> 5 != 1:
        raise Error("blosc: only the LZ4 compressor is supported")
    if ts == 0 or bs == 0:
        raise Error("blosc: bad typesize or blocksize")
    var out = List[UInt8](length=nb, fill=0)
    var nblocks = (nb + bs - 1) // bs
    for b in range(nblocks):
        var base = b * bs
        var neblock = min(bs, nb - base)
        var p = _le32(c, 16 + 4 * b)
        # DONT_SPLIT (0x10) keeps the block whole; otherwise one stream per typesize byte
        var streams = 1 if flags & 0x10 != 0 else ts
        var sub = neblock // streams
        var blk = List[UInt8]()
        for s in range(streams):
            var csz = _le32(c, p)
            p += 4
            var n_s = sub if s < streams - 1 else neblock - sub * (streams - 1)
            if p + csz > len(c):
                raise Error("blosc: truncated split")
            if csz == n_s:
                for k in range(n_s):
                    blk.append(c[p + k])
            else:
                var part = List[UInt8](length=csz, fill=0)
                for k in range(csz):
                    part[k] = c[p + k]
                var dec = lz4_decode(part, n_s)
                for k in range(n_s):
                    blk.append(dec[k])
            p += csz
        if flags & 1 != 0:
            # unshuffle: byte j of element i sits at j * (count) + i; a tail
            # shorter than one element stays as it is
            var count = neblock // ts
            for i in range(count):
                for j in range(ts):
                    out[base + i * ts + j] = blk[j * count + i]
            for k in range(count * ts, neblock):
                out[base + k] = blk[k]
        else:
            for k in range(neblock):
                out[base + k] = blk[k]
    return out^
