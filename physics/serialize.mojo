"""Scene serialization: exact save/load of a `ContactScene6[QuatBody6]`.

The format is a flat stream of space-separated INTEGER tokens (version tag
first); every float is stored as its raw f32 bit pattern (`to_bits`), so a
round trip is exact and a loaded scene continues BIT-IDENTICALLY -- which
requires saving everything dynamical, including the cross-frame warm-start
cache (`_CPair` impulse accumulators + manifolds), joint accumulators, and
(audit F20) the contact-event stream's own state (`events_on`/
`_prev_keys`), so events continue identically too, not just rigid/soft
state.

`physics.solver6.write_state`/`read_state` decide WHICH fields make up a
snapshot and in what order (the solver's job, F5): they live next to
`ContactScene6` and walk its fields directly, so a new per-body list cannot
be added to the scene and forgotten here the way this module used to be
able to (it used to re-implement `add` by appending to each of
`ContactScene6`'s lists by hand). This module decides only HOW each field
is encoded, by implementing `physics.state_io.StateWriter`/`StateReader` --
it no longer touches scene lists directly at all.

The on-disk format is fixed at f32 bit patterns deliberately, independent of
`geometry.vec.WorldType`: it is a wire format, not the world's compute dtype,
and changing it would break every saved scene. `_fbits`/`_TextReader.rf`
assert at comptime that `WorldType == DType.float32`, so a future switch to
f64 fails the build here instead of silently truncating precision on
save/load.

Truncated or corrupt input raises (F20): `_TextReader` bounds-checks every
token read instead of indexing past the end, and `read_state` range-checks
every body/joint index it reads.
"""

from geometry.vec import Real, Vec3, WorldType
from physics.rigid6 import QuatBody6
from physics.solver6 import ContactScene6, write_state, read_state
from physics.state_io import StateWriter, StateReader

comptime _VERSION = 2
"""Bumped from 1 in ROADMAP 17.0g-2: each body's fixed-size fields grew by
five tokens (`motion`, `friction`, `friction_combine`, `restitution_combine`,
`can_sleep` -- `physics.solver6.write_state`'s docstring), so a v1 snapshot
would silently misalign every read past that point rather than fail
cleanly. The version check below turns that into an explicit, early
rejection instead."""


def _fbits(f: Real) -> Int:
    comptime assert WorldType == DType.float32, (
        "physics/serialize.mojo's on-disk format is fixed at f32 bit"
        " patterns; a WorldType switch needs an explicit format migration,"
        " not a silent bit-width change"
    )
    return Int(Float32(f).to_bits())


struct _TextWriter(StateWriter, Movable, Deinitable):
    """Concrete `StateWriter`: accumulates the space-separated token stream
    `write_state` describes into `s`."""

    var s: String

    def __init__(out self):
        self.s = String()

    def wi(mut self, i: Int):
        self.s += String(i) + " "

    def wf(mut self, f: Real):
        self.s += String(_fbits(f)) + " "

    def wv(mut self, v: Vec3):
        self.wf(v[0])
        self.wf(v[1])
        self.wf(v[2])


struct _TextReader(StateReader, Movable, Deinitable):
    """Concrete `StateReader`: a bounds-checked cursor over the token
    stream. Every read raises instead of indexing past the end when the
    input is truncated (F20 -- the previous `_Reader.i` didn't)."""

    var toks: List[String]
    var at: Int

    def __init__(out self, data: String):
        self.toks = List[String]()
        for t in data.split(" "):
            if t.byte_length() > 0:
                self.toks.append(String(t))
        self.at = 0

    def ri(mut self) raises -> Int:
        if self.at >= len(self.toks):
            raise Error(
                "physics.serialize: truncated snapshot (expected another"
                " token at position " + String(self.at) + ")"
            )
        var v = atol(self.toks[self.at])
        self.at += 1
        return v

    def rf(mut self) raises -> Real:
        comptime assert WorldType == DType.float32, (
            "physics/serialize.mojo's on-disk format is fixed at f32 bit"
            " patterns; a WorldType switch needs an explicit format"
            " migration, not a silent bit-width change"
        )
        var u = UInt32(self.ri())
        return Real(Pointer(to=u).unsafe_bitcast[Float32]()[])

    def rv(mut self) raises -> Vec3:
        var x = self.rf()
        var y = self.rf()
        var z = self.rf()
        return Vec3(x, y, z, 0)


def scene_to_string(sc: ContactScene6[QuatBody6]) raises -> String:
    var w = _TextWriter()
    w.wi(_VERSION)
    write_state(sc, w)
    return w.s.copy()


def scene_from_string(data: String) raises -> ContactScene6[QuatBody6]:
    var r = _TextReader(data)
    if r.ri() != _VERSION:
        raise Error("scene format version mismatch")
    var sc = ContactScene6[QuatBody6]()
    read_state(sc, r)
    return sc^
