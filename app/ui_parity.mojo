"""Native / wasm64 parity probe for ui/ (ludens-engine #17): layout hash and widget draw-list hash.

`main` prints the hashes for the native build; `ui_parity_run` is exported for wasm64. Both call the same
functions in `ui/testing.mojo`."""
from ui.testing import layout_parity_hash, widget_parity_hash


@export
def ui_parity_run(out_ptr: UInt64) abi("C") -> Int32:
    """Writes [layout hash, widget hash] to out_ptr (2 x u64). 0 = ok."""
    try:
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = layout_parity_hash(12345, 200)
        out[1] = widget_parity_hash()
        return 0
    except e:
        print("ui_parity_run:", e)
        return -1


def main() raises:
    print("layout", layout_parity_hash(12345, 200), "widgets", widget_parity_hash())
