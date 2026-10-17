"""Soft bodies and cloth in still water (ROADMAP 17.59): the analytic
`WaterVolume` of `physics.fields` (a horizontal surface, a footprint, a
density), applied to particles instead of rigid shapes. Call once per frame
before the body's own step; both change velocities only.

  * `soft_water(sb, waters, gravity, dt, volume)`: every `SoftBody`
    particle stands for volume / n of the body as a horizontal slab of
    thickness a = (volume / n)^(1/3); its submerged fraction
    f = clamp((surface - y) / a + 1/2, 0, 1) gives buoyancy
    -rho_w g (volume / n) f / m_i and the water's linear drag,
    v *= 1 - lin_drag f dt (`WaterVolume.lin_drag`, as for rigid bodies).
  * `cloth_water(cloth, waters, gravity, dt, density, thickness, cd)`:
    per triangle
    whose centroid is under the surface, buoyancy rho_w g A thickness and
    pressure drag 1/2 rho_w cd A (v . n)^2 against the normal component of
    its velocity, spread over its unpinned corners. The drag is solved
    implicitly in the normal velocity (k v'|v'| dt + v' = v has a closed
    form): explicitly, a light sheet's drag step overshoots (measured:
    1 kg/m^2 at 1/60 s, dv / v = 1.3 per step).

Both are one-way (still water: nothing pushes the water) and treat the
surface as flat.
"""

from std.math import sqrt
from geometry.vec import Real, Vec3, cross, dot, length
from .fields import WaterVolume
from .softbody import SoftBody
from .cloth import MeshCloth


def _inside_footprint(p: Vec3, w: WaterVolume) -> Bool:
    return p[0] >= w.lo[0] and p[0] <= w.hi[0] and p[2] >= w.lo[2] and p[2] <= w.hi[2] and p[1] >= w.lo[1]


def soft_water(mut sb: SoftBody, waters: List[WaterVolume], gravity: Vec3, dt: Real, volume: Real) raises:
    """Buoyancy and drag on every particle (module note)."""
    if not (volume > 0) or not (dt > 0):
        raise Error("soft_water: volume and dt must be > 0")
    var n = len(sb.pts)
    if n == 0:
        return
    var vp = volume / Real(n)
    var a = Real(Float64(vp) ** (1.0 / 3.0))
    for i in range(n):
        var p = sb.pts[i]
        if p.w <= 0:
            continue
        for k in range(len(waters)):
            ref wv = waters[k]
            if not _inside_footprint(p.x, wv):
                continue
            var frac = min(max((wv.hi[1] - p.x[1]) / a + 0.5, Real(0)), Real(1))
            if frac <= 0:
                continue
            var v = p.v + gravity * (-wv.density * vp * frac * p.w * dt)
            v = v * max(1 - wv.lin_drag * frac * dt, Real(0))
            sb.pts[i].v = v
            break


def _implicit_drag(vn: Real, k: Real) -> Real:
    """v' with v' + k v'|v'| = vn (k = drag coefficient * dt / mass)."""
    if k <= 0 or vn == 0:
        return vn
    var s = Real(1) if vn > 0 else Real(-1)
    var a = abs(vn)
    return s * (-1 + sqrt(1 + 4 * k * a)) / (2 * k)


def cloth_water(mut c: MeshCloth, waters: List[WaterVolume], gravity: Vec3, dt: Real, density: Real, thickness: Real, cd: Real = 1.2) raises:
    """Buoyancy and normal pressure drag per submerged triangle (module
    note). `density` is the cloth's areal density (kg/m^2, as given to
    `MeshCloth`): a triangle's mass is area * density, a third of it at
    each corner."""
    if not (density > 0) or not (thickness >= 0) or not (cd >= 0) or not (dt > 0):
        raise Error("cloth_water: density > 0, thickness, cd >= 0 and dt > 0")
    var nt = len(c.tris) // 3
    # every triangle reads the velocities the call started with: reading
    # them as earlier triangles changed them under-applied the drag at
    # shared vertices (an interior vertex got 60 % of it)
    var v0 = c.v.copy()
    for t in range(nt):
        var ia = c.tris[3 * t]
        var ib = c.tris[3 * t + 1]
        var ic = c.tris[3 * t + 2]
        var cen = (c.x[ia] + c.x[ib] + c.x[ic]) * (1.0 / 3.0)
        for k in range(len(waters)):
            ref wv = waters[k]
            if not _inside_footprint(cen, wv) or cen[1] > wv.hi[1]:
                continue
            var nrm = cross(c.x[ib] - c.x[ia], c.x[ic] - c.x[ia])
            var l2 = length(nrm)
            if not (l2 > 0):
                break
            var area = l2 * 0.5
            var nn = nrm * (1 / l2)
            var m = area * density
            var vavg = (v0[ia] + v0[ib] + v0[ic]) * (1.0 / 3.0)
            # buoyancy, as a velocity change of the triangle's mass
            var dv_b = gravity * (-wv.density * area * thickness * dt / m)
            # normal drag, implicit in the normal velocity this frame ends
            # with -- including the gravity the cloth's own step adds after
            # this (solved before it, a light sheet sank at 3x its terminal
            # velocity: g dt = 0.16 m/s at 1/60 s exceeds 0.13 m/s)
            var vn = dot(vavg + dv_b + gravity * dt, nn)
            var kq = 0.5 * wv.density * cd * area * dt / m
            var vn2 = _implicit_drag(vn, kq)
            var dv = dv_b + nn * (vn2 - vn)
            # a third of the triangle's momentum change to each free corner
            for q in range(3):
                var vi = c.tris[3 * t + q]
                if c.w[vi] > 0:
                    c.v[vi] = c.v[vi] + dv * (m / 3 * c.w[vi])
            break
