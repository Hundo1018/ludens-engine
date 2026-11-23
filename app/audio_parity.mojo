"""Native / wasm64 parity probe for the audio mixer (ludens-engine #120): the hashes of `audio_scene.parity_hashes`.

`main` prints them natively; `audio_parity_run` is exported for wasm64 (scripts/audio_same.py compares the two)."""
from audio_scene import PARITY_VALUES, parity_hashes


@export
def audio_parity_run(out_ptr: UInt64) abi("C") -> Int32:
    """Writes PARITY_VALUES u64 to out_ptr. 0 = ok."""
    try:
        var v = parity_hashes()
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        for i in range(PARITY_VALUES):
            out[i] = v[i]
        return 0
    except e:
        print("audio_parity_run:", e)
        return -1


def main() raises:
    var v = parity_hashes()
    var line = String("audio")
    for i in range(len(v)):
        line += " " + String(v[i])
    print(line)
