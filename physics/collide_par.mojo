"""Parallel narrowphase and contact prep (ROADMAP 17.54).

`ContactScene6._collect_pairs` enumerates candidate pairs in the canonical
(i < j) ascending order the Gauss-Seidel solve and the warm start depend on
(`collision.contact_gen.collect_bp_pairs`). Both stages here keep that
order exactly, so the output is bit-identical to the serial loop for any
worker count and any `Dispatch`:

  * narrowphase: the candidate list is cut into fixed chunks; each item runs
    `try_pair` over one chunk into its own buffers, and the buffers are
    concatenated in chunk order afterwards. `try_pair` only reads the
    colliders, poses and velocities.
  * prep: `make_contact` per raw contact, written to its own slot. It reads
    the body set, the colliders and last frame's cache.

Both run through `scheduler.dispatch` (17.75), so a host job system can run
the items. Below `NARROW_PAR_MIN` candidates the caller stays serial (the
fan-out costs more than it saves; `bench_collide_par` measures where).
"""

from std.collections import Dict
from scheduler.dispatch import Dispatch, Task, dispatch_for
from geometry.vec import Real, Vec3
from collision.collider_set import ColliderSet, Pose3
from collision.contact_gen import RawContact, try_pair
from .rigid6 import Body6
from .body_set import BodySet
from .contact6 import ContactConstraint, make_contact, make_sensor_contact

comptime NARROW_PAR_MIN = 256
"""Fewest candidate pairs for which `_collect_pairs` fans out (64 box
pairs cost 0.6 ms more with 4 workers than serially, `bench_collide_par`)."""
comptime _CHUNK_MIN = 16


struct _NarrowTask(Task):
    var col: Pointer[ColliderSet, MutUntrackedOrigin]
    var poses: Pointer[List[Pose3], MutUntrackedOrigin]
    var vels: Pointer[List[Vec3], MutUntrackedOrigin]
    var ci: Pointer[List[Int], MutUntrackedOrigin]
    var cj: Pointer[List[Int], MutUntrackedOrigin]
    var outs: Pointer[List[List[RawContact]], MutUntrackedOrigin]
    var souts: Pointer[List[List[RawContact]], MutUntrackedOrigin]
    var counts: Pointer[List[Int], MutUntrackedOrigin]
    var scounts: Pointer[List[Int], MutUntrackedOrigin]
    var chunk: Int
    var spec_dt: Real
    var margin_base: Real

    def __init__(
        out self,
        mut col: ColliderSet,
        mut poses: List[Pose3],
        mut vels: List[Vec3],
        mut ci: List[Int],
        mut cj: List[Int],
        mut outs: List[List[RawContact]],
        mut souts: List[List[RawContact]],
        mut counts: List[Int],
        mut scounts: List[Int],
        chunk: Int,
        spec_dt: Real,
        margin_base: Real,
    ):
        self.col = Pointer(to=col).unsafe_origin_cast[MutUntrackedOrigin]()
        self.poses = Pointer(to=poses).unsafe_origin_cast[MutUntrackedOrigin]()
        self.vels = Pointer(to=vels).unsafe_origin_cast[MutUntrackedOrigin]()
        self.ci = Pointer(to=ci).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cj = Pointer(to=cj).unsafe_origin_cast[MutUntrackedOrigin]()
        self.outs = Pointer(to=outs).unsafe_origin_cast[MutUntrackedOrigin]()
        self.souts = Pointer(to=souts).unsafe_origin_cast[MutUntrackedOrigin]()
        self.counts = Pointer(to=counts).unsafe_origin_cast[MutUntrackedOrigin]()
        self.scounts = Pointer(to=scounts).unsafe_origin_cast[MutUntrackedOrigin]()
        self.chunk = chunk
        self.spec_dt = spec_dt
        self.margin_base = margin_base

    def run(self, k: Int):
        var lo = k * self.chunk
        var hi = min(lo + self.chunk, len(self.ci[]))
        var o = List[RawContact]()
        var so = List[RawContact]()
        for c in range(lo, hi):
            var i = self.ci[][c]
            var j = self.cj[][c]
            var n0 = len(o)
            var s0 = len(so)
            try_pair(
                self.col[], i, j, self.poses[][i], self.poses[][j],
                self.vels[][i], self.vels[][j], self.spec_dt, o, so, self.margin_base,
            )
            self.counts[][c] = len(o) - n0
            self.scounts[][c] = len(so) - s0
        self.outs[][k] = o^
        self.souts[][k] = so^


def narrow_parallel(
    mut colliders: ColliderSet,
    mut poses: List[Pose3],
    mut vels: List[Vec3],
    mut ci: List[Int],
    mut cj: List[Int],
    spec_dt: Real,
    margin_base: Real,
    mut raws: List[RawContact],
    mut sraws: List[RawContact],
    mut counts: List[Int],
    mut scounts: List[Int],
    workers: Int,
    dispatch: Dispatch,
):
    """`try_pair` over candidates (ci[c], cj[c]) in chunks, appended to
    `raws` / `sraws` in candidate order (bit-identical to the serial loop).
    `counts[c]` / `scounts[c]` (pre-sized to the candidate count) receive
    how many contacts candidate c produced. `colliders`, `poses` and `vels`
    are only read."""
    var n = len(ci)
    if n == 0:
        return
    var chunk = max(_CHUNK_MIN, n // 256)
    var nchunk = (n + chunk - 1) // chunk
    var outs = List[List[RawContact]](capacity=nchunk)
    var souts = List[List[RawContact]](capacity=nchunk)
    for _ in range(nchunk):
        outs.append(List[RawContact]())
        souts.append(List[RawContact]())
    var task = _NarrowTask(colliders, poses, vels, ci, cj, outs, souts, counts, scounts, chunk, spec_dt, margin_base)
    dispatch_for(dispatch, task, nchunk, workers)
    for k in range(nchunk):
        for c in range(len(outs[k])):
            raws.append(outs[k][c].copy())
        for c in range(len(souts[k])):
            sraws.append(souts[k][c].copy())


struct _PrepTask[B: Body6](Task):
    var bset: Pointer[BodySet[Self.B], MutUntrackedOrigin]
    var col: Pointer[ColliderSet, MutUntrackedOrigin]
    var cache: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var cidx: Pointer[Dict[Int, Int], MutUntrackedOrigin]
    var raws: Pointer[List[RawContact], MutUntrackedOrigin]
    var out: Pointer[List[ContactConstraint], MutUntrackedOrigin]
    var warm: Bool
    var match_scale: Real

    def __init__(
        out self,
        mut bset: BodySet[Self.B],
        mut col: ColliderSet,
        mut cache: List[ContactConstraint],
        mut cidx: Dict[Int, Int],
        mut raws: List[RawContact],
        mut out: List[ContactConstraint],
        warm: Bool,
        match_scale: Real,
    ):
        self.bset = Pointer(to=bset).unsafe_origin_cast[MutUntrackedOrigin]()
        self.col = Pointer(to=col).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cache = Pointer(to=cache).unsafe_origin_cast[MutUntrackedOrigin]()
        self.cidx = Pointer(to=cidx).unsafe_origin_cast[MutUntrackedOrigin]()
        self.raws = Pointer(to=raws).unsafe_origin_cast[MutUntrackedOrigin]()
        self.out = Pointer(to=out).unsafe_origin_cast[MutUntrackedOrigin]()
        self.warm = warm
        self.match_scale = match_scale

    def run(self, c: Int):
        self.out[][c] = make_contact(self.bset[], self.col[], self.cache[], self.cidx[], self.raws[][c], self.warm, self.match_scale)


def prep_parallel[B: Body6](
    mut bset: BodySet[B],
    mut colliders: ColliderSet,
    mut cache: List[ContactConstraint],
    mut cidx: Dict[Int, Int],
    mut raws: List[RawContact],
    warm: Bool,
    workers: Int,
    dispatch: Dispatch,
    match_scale: Real = 1,
) -> List[ContactConstraint]:
    """`make_contact` for every raw contact, each into its own slot (the
    same list the serial loop builds). Nothing passed in is written."""
    var out = List[ContactConstraint](capacity=len(raws))
    for c in range(len(raws)):
        out.append(make_sensor_contact(raws[c]))
    var task = _PrepTask[B](bset, colliders, cache, cidx, raws, out, warm, match_scale)
    dispatch_for(dispatch, task, len(raws), workers)
    return out^
