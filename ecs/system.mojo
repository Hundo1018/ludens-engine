"""Reusable fast-path systems over the archetype backend's SoA columns.

The generic `World.query2() + get/set` path is ergonomic but slow: it allocates a
`List[Entity]` per call and every `get`/`set` walks the entity index and a
type-erased slot. The *fast* path is to iterate an archetype's component columns
directly — they are contiguous (true SoA), so a system streams them and can even
SIMD over them. This module packages that fast path as engine API so game code
gets the locality benefit without re-deriving the column plumbing.

`integrate_simd` is the canonical example: `a += b * dt` over two numeric
component columns, vectorized at the hardware SIMD width. It is generic over the
component's element dtype and lane count (`SimdComponent`), so it works for any
such component — not just the `Vec2`/`float32` case. `integrate2_simd` is a
back-compat alias for the `Vec2`/`float32` shape.

SoA aligned columns are an archetype capability, so these take an
`ArchetypeBackend` concretely (not the `StorageBackend` trait). For the scalar
SoA path, iterate `backend.query2_views[A, B]()` and use `get_a`/`set_a` directly.
"""

from std.memory import alloc
from std.sys.info import simd_width_of
from geometry.vec import WorldType
from .component import ComponentType, SimdComponent
from .archetype import ArchetypeBackend

# The engine's world scalar type, derived from the single source of truth
# (`geometry.vec.WorldType`) so a future f64 switch needs one edit, not a hunt
# for every hard-coded `float32`.
comptime F = WorldType


def integrate_simd[
    A: SimdComponent, B: SimdComponent, *CTs: ComponentType
](mut backend: ArchetypeBackend[*CTs], dt: Scalar[A.Dtype]):
    """`A += B * dt` column-wise with hardware-width SIMD, for **any** pair of
    `SimdComponent`s — any element dtype, any lane count. Iterates matching
    archetypes directly (no `query2_views` allocation) and treats each column as a
    flat `Scalar[A.Dtype]` buffer, so one vector step covers `simdwidthof` lanes;
    a scalar tail handles the remainder."""
    comptime dt_t = A.Dtype
    comptime W = simd_width_of[dt_t]()
    comptime LANES_PER = A.Width  # scalar lanes per component
    var bits = (1 << ArchetypeBackend[*CTs].slot_of[A]()) | (
        1 << ArchetypeBackend[*CTs].slot_of[B]()
    )
    for k in range(len(backend.archetypes)):
        if (backend.archetypes[k].mask & bits) == bits:
            var n = len(backend.archetypes[k].entities)
            var fa = backend.col[A](k)[].unsafe_ptr().unsafe_bitcast[Scalar[dt_t]]()
            var fb = backend.col[B](k)[].unsafe_ptr().unsafe_bitcast[Scalar[dt_t]]()
            var m = LANES_PER * n
            var i = 0
            while i + W <= m:
                fa.unsafe_store(i, fa.unsafe_load[width=W](i) + fb.unsafe_load[width=W](i) * dt)
                i += W
            while i < m:
                fa.unsafe_store(i, fa.unsafe_load(i) + fb.unsafe_load(i) * dt)
                i += 1


def integrate2_simd[
    A: SimdComponent, B: SimdComponent, *CTs: ComponentType
](mut backend: ArchetypeBackend[*CTs], dt: Scalar[A.Dtype]):
    """Back-compat entry point for `Vec2`/`float32` components; delegates to the
    generic `integrate_simd`."""
    integrate_simd[A, B](backend, dt)
