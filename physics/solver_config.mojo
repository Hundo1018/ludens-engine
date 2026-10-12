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
from scheduler.dispatch import Dispatch


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

    # Cap on the soft push-out speed (m/s) when resolving penetration
    # (`contact6.solve_contact`'s bias clamp, a literal -4 before ROADMAP
    # 17.75 found it with the unit-scale similarity test).
    var max_push_speed: Real

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
    var dispatch: Dispatch  # who runs the parallel fan-outs (ROADMAP 17.75)

    def __init__(out self):
        self.margin_base = SPEC_BASE
        self.lin_sleep_tol = 0.01
        self.ang_sleep_tol = 0.05
        self.sleep_time = 0.5
        self.restitution_threshold = 1.0
        self.max_push_speed = 4
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
        self.dispatch = Dispatch.parallel()

    def validated(self) raises -> Self:
        """Raise if any tuning knob is outside the range the solver assumes
        (ROADMAP 17.0h / audit E5): `substeps`/`iters` < 1, `hertz` <= 0, or
        `zeta` < 0 each lead to a division producing `inf`/`NaN` inside
        `step`'s soft-constraint coefficients (`h = inf`, propagating to
        every body every substep).

        This is the RAISING half of the "invalid caller input at a public
        API" row in `docs/ARCHITECTURE.md` S2 for `step`/`step_soft`'s
        knobs. It is deliberately a method a caller opts into, not something
        `step`/`step_soft` call on every invocation: both have on the order
        of a hundred existing call sites across tests/benchmarks/examples,
        and making either of them `raises` would force every one of those
        (plus every caller of THEM) to become `raises` too -- exactly the
        large-signature-sweep compile-cost cliff `.campaign/mojo_1.1_migration
        .md` warns `physics` is prone to. Instead: a caller building a
        `SolverConfig` from untrusted input calls `.validated()` once at that
        boundary (raising is cheap there -- it is not a hot path), and `step`
        itself only `debug_assert`s the same invariants (terminate-on-bug,
        zero cost when assertions are off) as defence against a config that
        skipped validation, per the same file's guidance to prefer
        validate-once objects over a raising hot path."""
        if self.substeps < 1:
            raise Error("SolverConfig.validated: substeps must be >= 1")
        if self.iters < 1:
            raise Error("SolverConfig.validated: iters must be >= 1")
        if self.hertz <= 0:
            raise Error("SolverConfig.validated: hertz must be > 0")
        if self.zeta < 0:
            raise Error("SolverConfig.validated: zeta must be >= 0")
        return self


@fieldwise_init
struct UnitScale(Copyable, ImplicitlyCopyable, Movable):
    """How many host length units make one meter (ROADMAP 17.75): 1 for an
    engine working in meters, 100 for Unreal's centimetres, 0.01 for a host
    that counts in hundreds of meters. The core works in whatever unit its
    inputs use -- positions, extents, velocities, gravity -- and only the
    solver's ABSOLUTE length tolerances need telling: `apply` returns a copy
    of a `SolverConfig` with every length-dimensioned knob multiplied by
    `per_meter` (speculative margin in m, linear sleep threshold and
    restitution threshold and push-out speed cap in m/s). Angular thresholds (rad/s), times (s) and
    the dimensionless soft-constraint knobs are unit-free and unchanged.
    `test_unit_scale` checks the claim by similarity: a scene with every
    length multiplied by 2^k, stepped with `UnitScale(2^k)`, must follow the
    original trajectory times 2^k."""

    var per_meter: Real

    def apply(self, cfg: SolverConfig) -> SolverConfig:
        var c = cfg
        c.margin_base = cfg.margin_base * self.per_meter
        c.lin_sleep_tol = cfg.lin_sleep_tol * self.per_meter
        c.restitution_threshold = cfg.restitution_threshold * self.per_meter
        c.max_push_speed = cfg.max_push_speed * self.per_meter
        return c
