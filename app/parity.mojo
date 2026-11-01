"""Native / web parity probe: one fixed schedule on the shared Sim, hashed.

    frames x ( step(1/60), then `blocks` audio blocks of AUDIO_BLOCK frames )  ->  world hash, PCM hash

Built for native (`main` prints the hashes) and for wasm64 (`parity_run` is exported); the JS and native drivers
only call this, so neither can change the schedule."""
from sim import Sim, AUDIO_BLOCK


def _fnv(h: UInt64, bits: UInt32) -> UInt64:
    return (h ^ UInt64(bits)) * UInt64(0x100000001B3)


def run(frames: Int, blocks: Int) raises -> Tuple[UInt64, UInt64, Int]:
    """(world hash, PCM hash over every rendered sample's bit pattern, contact events seen)."""
    var s = Sim()
    var pcm = UInt64(0xCBF29CE484222325)
    for _ in range(frames):
        s.step(1.0 / 60.0)
        for _ in range(blocks):
            s.render_audio(AUDIO_BLOCK)
            for i in range(AUDIO_BLOCK * 2):
                pcm = _fnv(pcm, UInt32(s.pcm[i].to_bits()))
    return (s.world.hash(), pcm, s.contacts)


@export
def parity_run(frames: Int32, blocks: Int32, out_ptr: UInt64) abi("C") -> Int32:
    """Writes [world hash, PCM hash, contacts] to out_ptr (3 x u64). 0 = ok."""
    try:
        var r = run(Int(frames), Int(blocks))
        var out = Pointer[UInt64, MutUntrackedOrigin](unsafe_from_address=Int(out_ptr))
        out[0] = r[0]
        out[1] = r[1]
        out[2] = UInt64(r[2])
        return 0
    except e:
        print("parity_run:", e)
        return -1


def main() raises:
    var r = run(240, 4)
    print("world", r[0], "pcm", r[1], "contacts", r[2])
