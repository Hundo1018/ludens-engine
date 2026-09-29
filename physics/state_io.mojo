"""Trait seam between a solver's snapshot (`physics.solver6.write_state`/
`read_state` -- audit F5/F20) and the on-disk format (`physics.serialize`).

`write_state`/`read_state` decide WHICH fields a snapshot needs and in what
order (physics's job -- they live next to `ContactScene6` and walk its
fields directly, so a new per-body list cannot be added to the scene and
forgotten here the way `physics/serialize.mojo` used to be able to). A
`StateWriter`/`StateReader` implementation decides HOW each one is encoded:
text tokens, f32 bit patterns, a version header, all `physics/serialize
.mojo`'s job. `physics/solver6.mojo` and `physics/serialize.mojo` cannot
import each other (`serialize` already imports `solver6.ContactScene6`, so
the reverse would be a module cycle inside the `physics` package, forbidden
by docs/ARCHITECTURE.md S1) -- this small module is the third point both
import instead.

A `StateReader` is a plain sequential cursor, not a keyed format: every
method may be called only in the exact order the matching `StateWriter`
calls were made in. `read_state` propagates a `StateReader`'s `raises`
instead of ever reading past the end of a truncated snapshot
(docs/ARCHITECTURE.md S2's environment-failure class)."""

from geometry.vec import Real, Vec3


trait StateWriter:
    def wi(mut self, i: Int):
        ...

    def wf(mut self, f: Real):
        ...

    def wv(mut self, v: Vec3):
        ...


trait StateReader:
    def ri(mut self) raises -> Int:
        ...

    def rf(mut self) raises -> Real:
        ...

    def rv(mut self) raises -> Vec3:
        ...
