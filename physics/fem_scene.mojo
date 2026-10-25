"""FEM bodies in the rigid scene (ROADMAP 17.58): `FemContactPort` couples
an `FemContinuum` to a `ContactScene6` through the 17.55 contract
(`couple_step(scene, port, fem, ...)`).

After the FEM step (`after`), every free node -- a sphere of radius
`radius` -- is pushed out of every collider of the scene, the way
`soft_couple.softbody_pass` treats lattice particles:

  * box: out through the face the node entered by: its start-of-step
    position relative to the box (node position minus its step, plus the
    box point's motion) is outside the inflated box on some axis, and the
    largest such excess picks the face; least penetration only when the
    node started inside. Least penetration alone let a heavy box slice
    into a block: once the box edge was in, nodes beside its side faces
    were pushed out sideways and the box sank between them (measured:
    13 cm into a block that should give 4 mm);
    sphere / capsule: radially from the closest interior point; hull,
    mesh, heightfield, SDF, ellipsoid, compound: the collider registry's
    `soft_particle_contact`;
  * Coulomb friction at position level (`soft_fric`: the slide relative to
    the body's contact-point motion is clamped to `mu` times the normal
    correction);
  * the node's velocity takes the correction over the step (dx / dt), and a
    dynamic body takes the equal and opposite impulse -m dx / dt at the
    contact point (woken if asleep), so momentum is exchanged, not created.

Step it with `fem_coupled_step(scene, port, fem, dt, ..., substeps)`: the
whole coupled tick (explicit FEM, contact, rigid step) at dt / substeps.
Measured on a 50 kg box dropped onto a 0.6 x 0.4 x 0.6 m block (E = 3e5,
`test_fem_scene`), with the coupling outside the FEM solve:
  * implicit FEM at 1/60 s: backward Euler hands back only m / (m + dt^2 k)
    of a light node's elastic impulse per step (~1/29 here), so the box sank
    9 cm into a block that compresses 3 mm under the same load as mass;
  * explicit FEM in 24 substeps, contact once per frame: the per-frame
    corrections blew the block up;
  * contact per substep, rigid step per frame: the box rests on the block
    but jitters and drifts 9 cm in 3 s (the box takes 24 corrections
    without moving);
  * everything per substep (16): the box rests on the block, drifting 2 cm
    in 3 s, with an undamped 8 Hz bounce of ~0.1 m/s left (position-level
    contact on an elastic support).

Node CCD (`ccd = True`, 17.58; off by default, results unchanged): each
node's swept segment over the step is cast against every collider
(`ray_collider`, in the body's frame to first order: the start point moves
with the body's contact-point velocity). A hit puts the node at the hit
point plus `radius` along the surface normal and outranks the closest-point push-out, which would eject a
node that crossed a thin collider's midplane out of the far side
(the lattice soft body's 17.46 rule). `test_fem_ccd` fires a block at a 2 cm
plate: without CCD nodes end beyond it, with CCD none.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, dot
from collision.collider_set import SHAPE_BOX, SHAPE_SPHERE, SHAPE_CAPSULE
from .rigid6 import Body6
from .solver6 import ContactScene6
from .continuum import FemContinuum
from .coupling import CouplingPort, couple_step
from .solver_config import SolverConfig
from diag.counters import Counters
from .soft_couple import soft_fric
from collision.world_query import ray_collider


struct FemContactPort(CouplingPort):
    comptime S = FemContinuum

    var radius: Real
    var mu: Real
    var contacts: Int  # node-collider contacts resolved in the last step
    var ccd: Bool  # swept node test (module note); default off
    var swept: Int  # contacts found by the sweep in the last step
    var start: List[Vec3]  # node positions before the continuum step (ccd)

    def __init__(out self, radius: Real, mu: Real = 0.5, ccd: Bool = False) raises:
        if not (radius > 0) or not (mu >= 0):
            raise Error("FemContactPort: radius > 0 and mu >= 0")
        self.radius = radius
        self.mu = mu
        self.contacts = 0
        self.ccd = ccd
        self.swept = 0
        self.start = List[Vec3]()

    def before[B: Body6](mut self, mut scene: ContactScene6[B], mut s: FemContinuum, dt: Real, gravity: Vec3) raises:
        if not self.ccd:
            return
        # the sweep starts where the node really was: x - v dt with the
        # end-of-step velocity is off under contact accelerations (measured:
        # a resting block gained energy and sank through a 4 mm plate)
        ref fb = s.body
        self.start.resize(len(fb.x), Vec3(0, 0, 0, 0))
        for i in range(len(fb.x)):
            self.start[i] = Vec3(fb.x[i], fb.y[i], fb.z[i], 0)

    def after[B: Body6](mut self, mut scene: ContactScene6[B], mut s: FemContinuum, dt: Real, gravity: Vec3) raises:
        if self.ccd:
            self.swept = 0
            self.contacts = 0
            if dt > 0:
                self._after_ccd(scene, s, dt)
            return
        self.contacts = 0
        if not (dt > 0):
            return
        var r = self.radius
        ref fb = s.body
        for i in range(len(fb.x)):
            if fb.inv_m[i] == 0:
                continue
            var x = Vec3(fb.x[i], fb.y[i], fb.z[i], 0)
            var v = Vec3(fb.vx[i], fb.vy[i], fb.vz[i], 0)
            var m = 1 / fb.inv_m[i]
            for b in range(len(scene.bset.bodies)):
                if scene.bset.is_removed(b):
                    continue
                var res = point_contact(scene, b, x, x - v * dt, r, dt)
                if not res[0]:
                    continue
                var nw = res[1]
                if self.mu > 0:
                    nw = soft_fric(scene.bset, b, x, x - v * dt, nw, res[2], dt, self.mu)
                var dx = nw - x
                x = nw
                v = v + dx * (1 / dt)
                self.contacts += 1
                if scene.bset.is_dynamic(b):
                    scene.bset.bodies[b].apply_impulse(dx * (-m / dt), nw)
                    if scene.bset.sleeping[b]:
                        scene.bset.sleeping[b] = False
                        scene.bset.sleep_timer[b] = 0
            fb.x[i] = x[0]
            fb.y[i] = x[1]
            fb.z[i] = x[2]
            fb.vx[i] = v[0]
            fb.vy[i] = v[1]
            fb.vz[i] = v[2]

    def _after_ccd[B: Body6](mut self, mut scene: ContactScene6[B], mut s: FemContinuum, dt: Real):
        """`after` with the swept test (module note). A separate method: adding
        the ccd branches inside `after` changed its compiled arithmetic and
        moved `test_fem_scene` in the last digits with ccd off."""
        self.contacts = 0
        self.swept = 0
        if not (dt > 0):
            return
        var r = self.radius
        ref fb = s.body
        for i in range(len(fb.x)):
            if fb.inv_m[i] == 0:
                continue
            var x = Vec3(fb.x[i], fb.y[i], fb.z[i], 0)
            var v = Vec3(fb.vx[i], fb.vy[i], fb.vz[i], 0)
            var m = 1 / fb.inv_m[i]
            for b in range(len(scene.bset.bodies)):
                if scene.bset.is_removed(b):
                    continue
                # with ccd the recorded start also picks the box's entry face
                var res = point_contact(scene, b, x, self.start[i], r, dt)
                var swept = False
                var s0 = self.start[i] + scene.bset.bodies[b].velocity_at(x) * dt
                var seg = x - s0
                var sl = sqrt(dot(seg, seg))
                if sl > r:
                    var hit = ray_collider(scene.colliders, b, scene.bset.pose3(b), s0, seg * (1 / sl), sl + r)
                    if hit.hit and not hit.start_solid and hit.t <= sl + r:
                        # the hit point plus r along the surface normal:
                        # backing up r along the segment instead leaves a
                        # node that started within r of the surface inside
                        # the band, sinking a little every step (measured:
                        # a resting block sank through a 4 mm plate)
                        res = (True, s0 + seg * (hit.t / sl) + hit.normal * (r + Real(1e-4)), hit.normal)
                        swept = True
                        self.swept += 1
                if not res[0]:
                    continue
                var nw = res[1]
                var dv = Vec3(0, 0, 0, 0)
                var dx = Vec3(0, 0, 0, 0)
                if swept:
                    # velocity-level response: the node was put back along
                    # its sweep, so v + dx / dt would add the whole distance
                    # as speed (measured: a block shot up to 260 m). Remove
                    # the approach speed along n relative to the body;
                    # Coulomb friction from that impulse.
                    var n = res[2]
                    var rel = v - scene.bset.bodies[b].velocity_at(nw)
                    var vn = dot(rel, n)
                    if vn < 0:
                        dv = n * (-vn)
                        var vt = rel - n * vn
                        var vtl = sqrt(dot(vt, vt))
                        if vtl > 0:
                            dv = dv - vt * (min(self.mu * (-vn), vtl) / vtl)
                    x = nw
                    v = v + dv
                else:
                    # unchanged expression order (FMA contraction): the
                    # non-ccd path stays bit-identical
                    if self.mu > 0:
                        nw = soft_fric(scene.bset, b, x, x - v * dt, nw, res[2], dt, self.mu)
                    dx = nw - x
                    x = nw
                    v = v + dx * (1 / dt)
                self.contacts += 1
                if scene.bset.is_dynamic(b):
                    scene.bset.bodies[b].apply_impulse(dv * (-m) if swept else dx * (-m / dt), nw)
                    if scene.bset.sleeping[b]:
                        scene.bset.sleeping[b] = False
                        scene.bset.sleep_timer[b] = 0
            fb.x[i] = x[0]
            fb.y[i] = x[1]
            fb.z[i] = x[2]
            fb.vx[i] = v[0]
            fb.vy[i] = v[1]
            fb.vz[i] = v[2]


def point_contact[B: Body6](scene: ContactScene6[B], b: Int, x: Vec3, x_prev: Vec3, r: Real, dt: Real) -> Tuple[Bool, Vec3, Vec3]:
    """(hit, target, outward normal) for a sphere of radius `r` at `x` (at
    `x_prev` a step ago) against body `b`'s collider (FEM nodes here, hair
    particles in `strand_ext`)."""
    var kind = scene.colliders.shape[b]
    ref body = scene.bset.bodies[b]
    if kind == SHAPE_BOX:
        var lp = body.to_local(x)
        var hh = scene.colliders.half[b]
        var pen = Real(1e30)
        var ax = -1
        comptime for k in range(3):
            var pk = (hh[k] + r) - abs(lp[k])
            if pk <= 0:
                return (False, x, Vec3(0, 0, 0, 0))
            if pk < pen:
                pen = pk
                ax = k
        # entry face: where the node was relative to the box a step ago
        var lq = body.to_local(x_prev + body.velocity_at(x) * dt)
        var out = Real(0)
        var side = Real(0)
        comptime for k in range(3):
            var ek = abs(lq[k]) - (hh[k] + r)
            if ek > out:
                out = ek
                ax = k
                side = Real(1) if lq[k] >= 0 else Real(-1)
        var n_local = Vec3(0, 0, 0, 0)
        var tl = lp
        comptime for k in range(3):
            if k == ax:
                var sg = side if side != 0 else (Real(1) if lp[k] >= 0 else Real(-1))
                n_local[k] = sg
                tl[k] = sg * (hh[k] + r)
        var n = body.act(n_local) - body.act(Vec3(0, 0, 0, 0))
        return (True, body.act(tl), n)
    if kind == SHAPE_SPHERE or kind == SHAPE_CAPSULE:
        var hh = scene.colliders.half[b]
        var cen = body.position()
        if kind == SHAPE_CAPSULE:
            var axw = body.act(Vec3(0, hh[1], 0, 0)) - cen
            var t = dot(x - cen, axw) / max(dot(axw, axw), Real(1e-12))
            t = min(max(t, Real(-1)), Real(1))
            cen = cen + axw * t
        var rr = hh[0] + r
        var d = x - cen
        var d2 = dot(d, d)
        if d2 >= rr * rr:
            return (False, x, Vec3(0, 0, 0, 0))
        var dl = sqrt(max(d2, Real(1e-12)))
        var n = d * (1 / dl) if d2 > 1e-12 else Vec3(0, 1, 0, 0)
        return (True, cen + n * rr, n)
    return scene.colliders.soft_particle_contact(b, scene.bset.pose3(b), x, r)


def fem_coupled_step[B: Body6](
    mut scene: ContactScene6[B], mut port: FemContactPort, mut fem: FemContinuum,
    dt: Real, gravity: Vec3, cfg: SolverConfig, mut counters: Counters, substeps: Int = 16,
) raises:
    """`couple_step` `substeps` times at dt / substeps (see the module note
    for why the rigid step is substepped too)."""
    var n = max(substeps, 1)
    var h = dt / Real(n)
    for _ in range(n):
        _ = couple_step(scene, port, fem, h, gravity, cfg, counters)
