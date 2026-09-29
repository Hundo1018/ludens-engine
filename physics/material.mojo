"""Per-body physics materials: combine modes (ROADMAP 17.23).

Before this, restitution combine was hardcoded to `max` (`solver6
._restitution_pass`) and friction was a single scalar (`mu`) threaded
through the whole solve as if every body shared one coefficient
(`solver6._solve_pair`'s `cap = mu * pr.acc[k]`). Real engines let each
body carry its own coefficient plus an opinion on how a PAIR's two
coefficients combine (Unity `PhysicMaterial.combine`, PhysX
`PxCombineMode`, Jolt `PhysicsMaterial`, UE `FrictionCombineMode`) --
`combine` is that arithmetic, `physics.body_set.BodySet` holds the
per-body coefficient + combine-mode choice.

Four modes, comptime constants so the per-contact dispatch (`combine`
runs once per solved pair, every substep) is a cheap small-int branch, not
a virtual call or a string lookup. The PAIR's mode is decided by PhysX's
rule: when the two bodies disagree, the HIGHER-VALUED mode wins -- so the
ordering below (AVERAGE < MIN < MULTIPLY < MAX) is itself part of the
contract, not just enum bookkeeping. AVERAGE is deliberately the lowest
priority: it is also the identity default (ROADMAP 17.0g-2's "defaults
must reproduce today exactly" rule), so a body that never opts into a
combine mode never silently overrides one that did.
"""

from geometry.vec import Real

comptime COMBINE_AVERAGE = 0
comptime COMBINE_MIN = 1
comptime COMBINE_MULTIPLY = 2
comptime COMBINE_MAX = 3


def combine(a: Real, b: Real, mode_a: Int, mode_b: Int) -> Real:
    """One pair's combined coefficient from its two bodies' own coefficient
    + combine-mode choice. PhysX rule: `max(mode_a, mode_b)` picks which
    formula runs (see the module docstring for why AVERAGE is 0 and MAX is
    3). `restitution`'s old hardcoded `max(a, b)` is `combine` with both
    modes fixed at `COMBINE_MAX` -- the identity BodySet's default
    `restitution_combine` reproduces; friction's old single shared `mu`
    (`a == b == mu`) is `combine` with both modes at the default
    `COMBINE_AVERAGE`, where `(mu + mu) * 0.5 == mu` bit-exactly (IEEE 754
    doubling then halving is exact for any finite float)."""
    var mode = max(mode_a, mode_b)
    if mode == COMBINE_MIN:
        return min(a, b)
    elif mode == COMBINE_MULTIPLY:
        return a * b
    elif mode == COMBINE_MAX:
        return max(a, b)
    else:
        return (a + b) * Real(0.5)
