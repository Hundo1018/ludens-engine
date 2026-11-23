"""Native / wasm64 parity probe for the SDF font (ludens-engine #116): glyph table hash, rasterised text hashes at three
sizes, glyph quad hash and the missing-glyph count, all from `ui.testing.font_parity_hashes`.

`main <file.lfont>` prints the values natively; `font_parity_run` is exported for wasm64 and takes the file's bytes, which
the page (scripts/font_same.py) copies into wasm memory."""
from ui.testing import FONT_PARITY_VALUES, font_parity_hashes
from std.sys import argv


@export
def font_parity_run(file_ptr: UInt64, file_len: UInt64, out_ptr: UInt64) abi("C") -> Int32:
    """Writes FONT_PARITY_VALUES u64 to out_ptr. 0 = ok."""
    try:
        var bytes = List[UInt8](length=Int(file_len), fill=0)
        var src = Pointer[UInt8, MutUntrackedOrigin](unsafe_from_address=Int(file_ptr))
        for i in range(Int(file_len)):
            bytes[i] = src[i]
        var vals = font_parity_hashes(bytes^)
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        for i in range(FONT_PARITY_VALUES):
            out[i] = vals[i]
        return 0
    except e:
        print("font_parity_run:", e)
        return -1


def main() raises:
    var args = argv()
    var path = String(args[1])
    var bytes: List[UInt8]
    with open(path, "r") as f:
        bytes = f.read_bytes()
    var v = font_parity_hashes(bytes^)
    var line = String("font")
    for i in range(len(v)):
        line += " " + String(v[i])
    print(line)
