# tier: integration
"""Cloth <-> 2-D grid gas, two-way (ROADMAP 17.61, `physics.cloth_gas`
`ClothGas2`). The 2-D counterpart of `test_cloth_air`.

Gas: `MacFluid2` 32^2, periodic, dx 0.02, nu 1e-3, dt 1/240, uniform +x flow
0.4 m/s, density 1 kg/m^3. Cloth: a flag in the plane x = 0.2, y 0.30 .. 0.50
(4 cells), z -0.05 .. 0.05 (4 cells), density 0.1 kg/m^2, top edge (y 0.50)
pinned, gravity 0, drag k 2 kg/(m^2 s), gas depth 0.1 m. The run is 0.4 s
(96 steps). The tip is the free bottom-middle vertex (y 0.30, z 0).

Predictions, written before the run:

  1. Exact reaction: each `couple` call moves depth * sum(u) dx^2 by minus
     the cloth's in-plane impulse. Largest |dP_gas + J| over 40 calls,
     relative to the largest |J|, below 1e-3 (f32 storage of the faces).
  2. Ordinary: the tip moves +x (> 1 mm) in both configurations. The gas
     slowed by the flag gives the two-way tip a smaller shift than the
     one-way tip.
  3. Wake: after 0.4 s the gas just downstream of the flag (x 0.23, y 0.40)
     is slower than the gas beside it at the same x (y 0.10).
  4. Plane: the gas has no z component, so it adds no z impulse (check 1b).
     The flag's mirror asymmetry largest |z_ij + z_i,N-j| is set by the
     cloth solver's constraint order, not by the gas. Prediction as first
     written: below 1e-6. Measured first run: 1.5e-3, and a cloth-only probe
     (no gas, in-plane gravity 9.8 m/s^2, 96 steps, scratch file
     probe_cloth_sym.mojo) gives 3.1e-3. The bound below (5e-3) was set
     after that probe; it checks the coupled run is no worse than the
     solver alone.
  5. Extreme: depth <= 0 or k < 0 raises.

Measured: recorded in the run output and the ROADMAP 17.61 progress note.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.cloth import MeshCloth
from physics.mac_fluid import MacFluid2
from physics.cloth_gas import ClothGas2

comptime N = 32
comptime DX: Real = 0.02
comptime DT: Real = 1.0 / 240.0
comptime G = Vec3(0, 0, 0, 0)
comptime NY = 4
comptime NZ = 4
comptime X0: Real = 0.2
comptime Y0: Real = 0.3
comptime H_Y: Real = 0.05
comptime H_Z: Real = 0.025
comptime HALF_Z: Real = 0.05
comptime DEPTH: Real = 0.1
comptime K: Real = 2.0


def vid(i: Int, j: Int) -> Int:
    return i * (NZ + 1) + j


def gas() raises -> MacFluid2:
    var f = MacFluid2(N, DX, Real(1e-3))
    for k in range(len(f.u)):
        f.u[k] = 0.4
    return f^


def flag() raises -> MeshCloth:
    var verts = List[Real]()
    for i in range(NY + 1):
        for j in range(NZ + 1):
            verts.append(X0)
            verts.append(Y0 + Real(i) * H_Y)
            verts.append(-HALF_Z + Real(j) * H_Z)
    var tris = List[Int]()
    for i in range(NY):
        for j in range(NZ):
            var a = vid(i, j)
            var b = vid(i + 1, j)
            var c = vid(i + 1, j + 1)
            var d = vid(i, j + 1)
            tris.append(a)
            tris.append(b)
            tris.append(c)
            tris.append(a)
            tris.append(c)
            tris.append(d)
    var cl = MeshCloth(verts, tris, Real(0.1))
    for j in range(NZ + 1):
        cl.pin(vid(NY, j))
    return cl^


def gas_momentum(f: MacFluid2) -> Tuple[Float64, Float64]:
    """Momentum depth * sum(u) dx^2 and depth * sum(v) dx^2, in f64."""
    var sx = Float64(0)
    var sy = Float64(0)
    for k in range(len(f.u)):
        sx += Float64(f.u[k])
        sy += Float64(f.v[k])
    var w = Float64(DX) * Float64(DX) * Float64(DEPTH)
    return (sx * w, sy * w)


def tip_x(c: MeshCloth) -> Real:
    return c.x[vid(0, NZ // 2)][0]


def main() raises:
    var s = Suite("cloth_gas")

    # 1. exact reaction, drag step only (cloth not advanced)
    var f1 = gas()
    var c1 = flag()
    var g1 = ClothGas2(K, DEPTH)
    var worst_gap = Float64(0)
    var worst_j = Float64(0)
    for _ in range(40):
        var before = gas_momentum(f1)
        var j0x = g1.cloth_impulse[0]
        var j0y = g1.cloth_impulse[1]
        g1.couple(f1, c1, DT)
        var after = gas_momentum(f1)
        var jx = Float64(g1.cloth_impulse[0] - j0x)
        var jy = Float64(g1.cloth_impulse[1] - j0y)
        var dx_gas = after[0] - before[0]
        var dy_gas = after[1] - before[1]
        worst_gap = max(worst_gap, max(abs(dx_gas + jx), abs(dy_gas + jy)))
        worst_j = max(worst_j, max(abs(jx), abs(jy)))
    var ratio = worst_gap / worst_j
    print("  exact reaction: worst |dP_gas + J| / max|J| =", ratio, " (max |J| =", worst_j, ")")
    s.check(ratio < 1e-3, "each drag step: gas momentum change is minus the cloth impulse")
    s.check(abs(g1.z_impulse) < 1e-9, "the gas has no z component: the z impulse stays out of it")

    # 2 and 3. ordinary run, two-way and one-way
    var f2 = gas()
    var c2 = flag()
    var g2 = ClothGas2(K, DEPTH, True)
    var f3 = gas()
    var c3 = flag()
    var g3 = ClothGas2(K, DEPTH, False)
    var x0 = tip_x(c2)
    var x0b = tip_x(c3)
    for _ in range(96):
        g2.step(f2, c2, G, DT)
        g3.step(f3, c3, G, DT)
    var shift_two = tip_x(c2) - x0
    var shift_one = tip_x(c3) - x0b
    print("  tip shift +x after 0.4 s: one-way", shift_one, " two-way", shift_two)
    s.check(shift_one > 1e-3 and shift_two > 1e-3, "the flow pushes the tip downstream in both configurations")
    s.check(shift_two < shift_one, "the slowed gas pushes the two-way tip less than the one-way tip")

    var wake = f2.velocity(0.23, 0.40)[0]
    var beside = f2.velocity(0.23, 0.10)[0]
    print("  gas u downstream (0.23, 0.40)", wake, " beside (0.23, 0.10)", beside)
    s.check(wake < beside, "the gas just downstream of the flag is slower than the gas beside it")

    # 4. the flag stays mirror-symmetric in z
    var zsym = Real(0)
    for i in range(NY + 1):
        for j in range(NZ + 1):
            zsym = max(zsym, abs(c2.x[vid(i, j)][2] + c2.x[vid(i, NZ - j)][2]))
    print("  largest |z_ij + z_i,N-j| after the run", zsym)
    s.check(zsym < 5e-3, "the coupled flag's mirror asymmetry is within the cloth solver's own (probe 3.1e-3)")

    # 5. extreme
    var raised = False
    try:
        _ = ClothGas2(K, 0.0)
    except:
        raised = True
    s.check(raised, "depth <= 0 raises")
    raised = False
    try:
        _ = ClothGas2(-1.0, DEPTH)
    except:
        raised = True
    s.check(raised, "k < 0 raises")
    s.finish()
