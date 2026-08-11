"""Scene serialization: exact save/load of a `ContactScene6[QuatBody6]`.

The format is a flat stream of space-separated INTEGER tokens (version tag
first); every float is stored as its raw f32 bit pattern (`to_bits`), so a
round trip is exact and a loaded scene continues BIT-IDENTICALLY — which
requires saving everything dynamical, including the cross-frame warm-start
cache (`_CPair` impulse accumulators + manifolds) and joint accumulators.
Islands are recomputed each step and need no entry.
"""

from std.memory import UnsafePointer
from geometry.vec import Real, Vec3
from geometry.quat import Quat
from collision.manifold import ContactManifold
from collision.hull import HullShape
from collision.trimesh import TriMesh, HeightField
from physics.rigid6 import Inertia3, QuatBody6
from physics.solver6 import ContactScene6, Joint6, _CPair, _Half
from physics.softbody import SoftBody, _SP, _SEdge

comptime _VERSION = 1


def _fbits(f: Real) -> Int:
    return Int(Float32(f).to_bits())


def _wf(mut s: String, f: Real):
    s += String(_fbits(f)) + " "


def _wi(mut s: String, i: Int):
    s += String(i) + " "


def _wv(mut s: String, v: Vec3):
    _wf(s, v[0])
    _wf(s, v[1])
    _wf(s, v[2])


struct _Reader(Movable, ImplicitlyDeletable):
    var toks: List[String]
    var at: Int

    def __init__(out self, data: String):
        self.toks = List[String]()
        for t in data.split(" "):
            if t.byte_length() > 0:
                self.toks.append(String(t))
        self.at = 0

    def i(mut self) raises -> Int:
        var v = atol(self.toks[self.at])
        self.at += 1
        return v

    def f(mut self) raises -> Real:
        var u = UInt32(self.i())
        return Real(UnsafePointer(to=u).bitcast[Float32]()[])

    def v3(mut self) raises -> Vec3:
        var x = self.f()
        var y = self.f()
        var z = self.f()
        return Vec3(x, y, z)


def scene_to_string(sc: ContactScene6[QuatBody6]) raises -> String:
    var s = String()
    _wi(s, _VERSION)
    _wi(s, len(sc.bodies))
    for i in range(len(sc.bodies)):
        var b = sc.bodies[i]
        _wv(s, b.pos)
        _wf(s, b.q.x)
        _wf(s, b.q.y)
        _wf(s, b.q.z)
        _wf(s, b.q.w)
        _wv(s, b.vel)
        _wv(s, b.omega)
        _wf(s, b.inertia.mass)
        _wf(s, b.inertia.ix)
        _wf(s, b.inertia.iy)
        _wf(s, b.inertia.iz)
        _wv(s, sc.half[i].v)
        _wi(s, 1 if sc.statics[i] else 0)
        _wi(s, sc.shape[i])
        _wf(s, sc.restitution[i])
        _wi(s, 1 if sc.sleeping[i] else 0)
        _wf(s, sc.sleep_timer[i])
        _wi(s, Int(sc.category[i]))
        _wi(s, Int(sc.mask[i]))
        _wi(s, 1 if sc.sensor[i] else 0)
        # Shape payload for the kinds that keep their geometry in a side table.
        # A snapshot that restored a hull body without its vertices would load
        # cleanly and then index an empty table on the next contact, so the
        # geometry travels with the body even though a level mesh can be large:
        # this format is a full state snapshot, not an asset reference.
        if sc.shape[i] == 3:
            ref hl = sc.hulls[sc.hull_id[i]]
            _wi(s, len(hl.v))
            for k in range(len(hl.v)):
                _wf(s, hl.v[k])
        elif sc.shape[i] == 4:
            ref ms = sc.meshes[sc.mesh_id[i]]
            _wi(s, len(ms.v))
            for k in range(len(ms.v)):
                _wf(s, ms.v[k])
            _wi(s, len(ms.idx))
            for k in range(len(ms.idx)):
                _wi(s, ms.idx[k])
        elif sc.shape[i] == 5:
            ref hf = sc.fields[sc.mesh_id[i]]
            _wi(s, hf.nx)
            _wi(s, hf.nz)
            _wf(s, hf.cell)
            _wf(s, hf.ox)
            _wf(s, hf.oz)
            _wi(s, len(hf.h))
            for k in range(len(hf.h)):
                _wf(s, hf.h[k])
    _wi(s, len(sc.joints))
    for j in range(len(sc.joints)):
        var jt = sc.joints[j]
        _wi(s, jt.kind)
        _wi(s, jt.a)
        _wi(s, jt.b)
        _wv(s, jt.la)
        _wv(s, jt.lb)
        _wf(s, jt.rest)
        _wv(s, jt.axis_a)
        _wv(s, jt.axis_b)
        _wv(s, jt.acc)
        _wv(s, jt.acc_ang)
    _wi(s, len(sc.softs))
    for k in range(len(sc.softs)):
        _wf(s, sc.softs[k].alpha)
        _wf(s, sc.softs[k].radius)
        _wf(s, sc.softs[k].damp)
        _wf(s, sc.softs[k].mu)
        _wi(s, len(sc.softs[k].pts))
        for p in range(len(sc.softs[k].pts)):
            var pt = sc.softs[k].pts[p]
            _wv(s, pt.x)
            _wv(s, pt.v)
            _wf(s, pt.w)
        _wi(s, len(sc.softs[k].edges))
        for e in range(len(sc.softs[k].edges)):
            var ed = sc.softs[k].edges[e]
            _wi(s, ed.a)
            _wi(s, ed.b)
            _wf(s, ed.rest)
            _wf(s, ed.lam)
    _wi(s, len(sc.cache))
    for c in range(len(sc.cache)):
        var pr = sc.cache[c]
        _wi(s, pr.a)
        _wi(s, pr.b)
        _wi(s, pr.feat)  # triangle index for mesh contacts, 0 otherwise
        _wi(s, 1 if pr.m.hit else 0)
        _wv(s, pr.m.normal)
        _wi(s, pr.m.count)
        for p in range(4):
            _wv(s, pr.m.points[p])
            _wf(s, pr.m.depths[p])
            _wf(s, pr.acc[p])
            _wf(s, pr.acc_t1[p])
            _wf(s, pr.acc_t2[p])
            _wv(s, pr.ra[p])
            _wv(s, pr.rb[p])
            _wf(s, pr.vn0[p])
            _wf(s, pr.racc[p])
    return s^


def scene_from_string(data: String) raises -> ContactScene6[QuatBody6]:
    var r = _Reader(data)
    if r.i() != _VERSION:
        raise Error("scene format version mismatch")
    var sc = ContactScene6[QuatBody6]()
    var nb = r.i()
    for _ in range(nb):
        var pos = r.v3()
        var qx = r.f()
        var qy = r.f()
        var qz = r.f()
        var qw = r.f()
        var vel = r.v3()
        var omega = r.v3()
        var im = r.f()
        var ix = r.f()
        var iy = r.f()
        var iz = r.f()
        sc.bodies.append(
            QuatBody6(pos, Quat(qx, qy, qz, qw), vel, omega,
                      Inertia3(im, ix, iy, iz))
        )
        sc.half.append(_Half(r.v3()))
        sc.statics.append(r.i() == 1)
        var kind = r.i()
        sc.shape.append(kind)
        sc.restitution.append(r.f())
        sc.sleeping.append(r.i() == 1)
        sc.sleep_timer.append(r.f())
        sc.category.append(UInt32(r.i()))
        sc.mask.append(UInt32(r.i()))
        sc.sensor.append(r.i() == 1)
        sc.island.append(-1)
        sc.hull_id.append(-1)
        sc.mesh_id.append(-1)
        var bi = len(sc.bodies) - 1
        if kind == 3:
            var nv = r.i()
            var hv = List[Real](capacity=nv)
            for _ in range(nv):
                hv.append(r.f())
            sc.hull_id[bi] = len(sc.hulls)
            sc.hulls.append(HullShape(hv))
        elif kind == 4:
            var nv = r.i()
            var mv = List[Real](capacity=nv)
            for _ in range(nv):
                mv.append(r.f())
            var ni = r.i()
            var mi = List[Int](capacity=ni)
            for _ in range(ni):
                mi.append(r.i())
            sc.mesh_id[bi] = len(sc.meshes)
            sc.meshes.append(TriMesh(mv, mi))
        elif kind == 5:
            var nx = r.i()
            var nz = r.i()
            var cell = r.f()
            var ox = r.f()
            var oz = r.f()
            var nh = r.i()
            var hh = List[Real](capacity=nh)
            for _ in range(nh):
                hh.append(r.f())
            sc.mesh_id[bi] = len(sc.fields)
            sc.fields.append(HeightField(hh, nx, nz, cell, ox, oz))
    var nj = r.i()
    for _ in range(nj):
        var kind = r.i()
        var a = r.i()
        var b = r.i()
        var la = r.v3()
        var lb = r.v3()
        var rest = r.f()
        var axa = r.v3()
        var axb = r.v3()
        var acc = r.v3()
        var acca = r.v3()
        sc.joints.append(
            Joint6(kind, a, b, la, lb, rest, axa, axb, acc, acca)
        )
    var ns = r.i()
    for _ in range(ns):
        var sb = SoftBody()
        sb.alpha = r.f()
        sb.radius = r.f()
        sb.damp = r.f()
        sb.mu = r.f()
        var np = r.i()
        for _ in range(np):
            var x = r.v3()
            var v = r.v3()
            var w = r.f()
            sb.pts.append(_SP(x, v, w))
        var ne = r.i()
        for _ in range(ne):
            var ea = r.i()
            var eb = r.i()
            var er = r.f()
            var el = r.f()
            sb.edges.append(_SEdge(ea, eb, er, el))
        _ = sc.add_soft(sb^)
    var nc = r.i()
    for _ in range(nc):
        var a = r.i()
        var b = r.i()
        var feat = r.i()
        var m = ContactManifold[3]()
        m.hit = r.i() == 1
        m.normal = r.v3()
        m.count = r.i()
        var pr = _CPair(
            a, b, feat, m,
            InlineArray[Real, 4](fill=0), InlineArray[Real, 4](fill=0),
            InlineArray[Real, 4](fill=0),
            InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
            InlineArray[Vec3, 4](fill=Vec3(0, 0, 0)),
            InlineArray[Real, 4](fill=0), InlineArray[Real, 4](fill=0),
        )
        for p in range(4):
            pr.m.points[p] = r.v3()
            pr.m.depths[p] = r.f()
            pr.acc[p] = r.f()
            pr.acc_t1[p] = r.f()
            pr.acc_t2[p] = r.f()
            pr.ra[p] = r.v3()
            pr.rb[p] = r.v3()
            pr.vn0[p] = r.f()
            pr.racc[p] = r.f()
        sc.cache.append(pr)
    return sc^
