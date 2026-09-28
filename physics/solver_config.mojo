"""Solver tuning knobs, collected into one struct (audit finding F19).

Before this, `step_soft` took eleven positional/keyword flags as the only
way to tune a step, the fat-AABB/margin speculative-contact parity guarantee
depended on two separate `SPEC_BASE` literals (`collision/collider_set.mojo`
and `collision/contact_gen.mojo`) staying equal by hand, and the sleep/
restitution thresholds were comptime locals baked into `_update_sleep`/
`_restitution_pass` with no way to read or override them. `SolverConfig`
gives every one of those a name and one owner; `SPEC_BASE` itself now has
exactly one definition (`collision.collider_set.SPEC_BASE`), imported here
and by `collision.contact_gen`.

`ContactScene6.step(dt, gravity, cfg)` is the config-driven entry point.
`step_soft(dt, gravity, substeps=..., ...)` is now a thin forwarder that
builds a `SolverConfig` from its keyword arguments and calls `step`, so
every existing call site (~100 across tests/benchmarks/examples) keeps
compiling and behaving identically -- this is a behaviour-preserving
refactor (ROADMAP 17.0g-1), not a new step mode.
"""

from geometry.vec import Real
from collision.collider_set import SPEC_BASE


@fieldwise_init
struct SolverConfig(Copyable, ImplicitlyCopyable, Movable):
    """Every `step_soft` tuning knob plus the sleep/restitution thresholds
    that used to be comptime locals. `SolverConfig()`'s defaults reproduce
    the values every call site already had before this struct existed --
    constructing one and stepping with it is bit-identical to the old
    hardcoded behaviour (the identity gate for this commit)."""

    # Speculative-contact margin base (F19): defined once, in
    # `collision.collider_set`, so `ColliderSet.fat_aabb` and
    # `collision.contact_gen`'s per-pair margin can no longer drift apart.
    # Not yet threaded through those call sites as a runtime override --
    # that plumbing is out of scope for this behaviour-preserving commit.
    # This field exists so later config-driven code has one place to read
    # the value both of those already use.
    var margin_base: Real

    # Sleep thresholds (`_update_sleep`'s old comptime locals).
    var lin_sleep_tol: Real
    var ang_sleep_tol: Real
    var sleep_time: Real

    # Restitution: approach speed (m/s) above which the restitution pass
    # engages (`_restitution_pass`'s old comptime `REST_THRESH`).
    var restitution_threshold: Real

    # `step_soft`'s old keyword arguments; defaults unchanged.
    var substeps: Int
    var iters: Int
    var hertz: Real
    var zeta: Real
    var default_friction: Real  # old `mu` keyword
    var ccd: Bool
    var parallel: Bool
    var colored: Bool
    var broadphase: Bool
    var workers: Int

    def __init__(out self):
        self.margin_base = SPEC_BASE
        self.lin_sleep_tol = 0.01
        self.ang_sleep_tol = 0.05
        self.sleep_time = 0.5
        self.restitution_threshold = 1.0
        self.substeps = 4
        self.iters = 4
        self.hertz = 30
        self.zeta = 10
        self.default_friction = 0.5
        self.ccd = False
        self.parallel = False
        self.colored = False
        self.broadphase = False
        self.workers = 0
