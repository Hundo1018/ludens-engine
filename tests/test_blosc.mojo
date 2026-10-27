# tier: unit
"""Blosc 1 chunk decoding (ROADMAP 17.63, `geometry.blosc`).

The `.vdb` fixtures in test_vdb_zip cover real OpenVDB output. These cases pin
the edges: a memcpyed chunk, an LZ4 match that overlaps its own output
(offset 1), and the two errors a bad LZ4 block must raise.
"""

from harness.runner import Suite
from geometry.blosc import blosc_decode, lz4_decode


def _le32(v: Int) -> List[UInt8]:
    var b = List[UInt8]()
    for k in range(4):
        b.append(UInt8((v >> (8 * k)) & 255))
    return b^


def _chunk_header(flags: Int, nbytes: Int, blocksize: Int, cbytes: Int) -> List[UInt8]:
    var h = List[UInt8]()
    h.append(2)  # format version
    h.append(1)  # lz version
    h.append(UInt8(flags))
    h.append(4)  # typesize (f32)
    for b in _le32(nbytes):
        h.append(b)
    for b in _le32(blocksize):
        h.append(b)
    for b in _le32(cbytes):
        h.append(b)
    return h^


def main() raises:
    var s = Suite("blosc")

    # memcpyed chunk: the data follows the 16-byte header raw
    var payload = List[UInt8]()
    for i in range(8):
        payload.append(UInt8(10 + i))
    var mem = _chunk_header(2, 8, 8, 24)
    for b in payload:
        mem.append(b)
    var got = blosc_decode(mem, 8)
    var mem_ok = len(got) == 8
    for i in range(8):
        if mem_ok and got[i] != payload[i]:
            mem_ok = False
    s.check(mem_ok, "memcpyed chunk returns its payload")

    # LZ4 block: one literal 'A', then a match of 8 bytes at offset 1 (token 0x14)
    var lz = List[UInt8]()
    lz.append(0x14)
    lz.append(65)
    lz.append(1)
    lz.append(0)
    var nine = lz4_decode(lz, 9)
    var overlap_ok = len(nine) == 9
    for i in range(9):
        if overlap_ok and nine[i] != 65:
            overlap_ok = False
    s.check(overlap_ok, "LZ4 match at offset 1 repeats the literal")

    # an offset that reaches before the output start must raise
    var bad_off = List[UInt8]()
    bad_off.append(0x10)
    bad_off.append(66)
    bad_off.append(5)
    bad_off.append(0)
    var raised = False
    try:
        _ = lz4_decode(bad_off, 5)
    except:
        raised = True
    s.check(raised, "LZ4 offset before the output start raises")

    # a block whose output is not the chunk's size must raise
    var short = False
    try:
        _ = lz4_decode(lz, 8)
    except:
        short = True
    s.check(short, "LZ4 output longer than the stated size raises")
    s.finish()
