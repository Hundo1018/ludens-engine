"""The component contract.

Every component type carries a `comptime ID: Int` — a stable, unique, small
integer chosen by the user. The ID is how the storage backends map a component
*type* to a storage slot at compile time (this nightly has no type-equality
operator, so we compare IDs: `Self.CTs[i].ID == C.ID`). Keep IDs unique and
densely packed from 0 within a given world.

A component must be `Copyable & ImplicitlyCopyable` (stores copy values in and
out), `Movable`, and `ImplicitlyDeletable` (so it can live behind generic
storage). Components are plain data — no methods required.
"""


trait ComponentType(Copyable, ImplicitlyCopyable, Movable, ImplicitlyDeletable):
    comptime ID: Int


trait SimdComponent(ComponentType):
    """A numeric component whose payload is a flat run of `Width` `Dtype` lanes
    (e.g. a single `SIMD[float32, 2]` field). Declaring the element dtype and lane
    count lets `integrate_simd` vectorize any such component — any dtype, any
    width — not just the hardcoded `Vec2`/`float32`/width-8 case."""

    comptime Dtype: DType
    comptime Width: Int
