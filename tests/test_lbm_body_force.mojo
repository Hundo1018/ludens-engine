# tier: unit
"""LBM body force along any axis (ROADMAP 17.60, `Lbm.force_y` / `force_z`).

  1. Ordinary: a Poiseuille channel (walls at y = 0 and y = 30) driven
     along z matches the analytic parabola within 1 % after 8000 steps, as
     the one driven along x does (test_lbm_validation), and the two
     profiles agree within 0.2 % of the peak (measured 0.08 %: y / z use a
     source term after collision, x the velocity shift inside it --
     `Lbm._force_yz` says why).
  2. Integration: a channel with walls at x = 0 and x = 30 driven along y
     gives the same profile again (x <-> y relabelled).
  3. Extreme: an open periodic box driven along z gains F per cell per
     step: the mean velocity after 200 steps is 200 F / rho (1e-3); with
     force_y = force_z = 0 two lattices run identically (the x-only
     path's golden sections are unchanged, checked by the gate).
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_PERIODIC, CELL_SOLID

comptime N = 31
comptime NU: Real = 0.1
comptime F: Real = 1e-5


def _channel(axis_wall: Int, axis_force: Int) -> List[Real]:
    """Velocity along `axis_force` across the channel (walls normal to
    `axis_wall`), at the middle of the other axes."""
    var dims = [4, 4, 4]
    dims[axis_wall] = N
    var l = Lbm(dims[0], dims[1], dims[2], NU, BC_PERIODIC)
    for z in range(dims[2]):
        for y in range(dims[1]):
            for x in range(dims[0]):
                var c = [x, y, z]
                if c[axis_wall] == 0 or c[axis_wall] == N - 1:
                    l.flag[l.idx(x, y, z)] = CELL_SOLID
    l.init_uniform(1.0, 0, 0, 0)
    match axis_force:
        case 0:
            l.force_x = F
        case 1:
            l.force_y = F
        case _:
            l.force_z = F
    for _ in range(8000):
        l.step()
    var out = List[Real]()
    for k in range(N):
        var c = [2, 2, 2]
        c[axis_wall] = k
        out.append(l.velocity(l.idx(c[0], c[1], c[2]))[axis_force])
    return out^


def main() raises:
    var s = Suite("lbm_body_force")
    var px = _channel(1, 0)
    var pz = _channel(1, 2)
    var py = _channel(0, 1)
    var peak = Real(0)
    var dz = Real(0)
    var dy = Real(0)
    var wx = Real(0)
    var wy = Real(0)
    var wz = Real(0)
    var hw = Real(N - 2) * 0.5
    for k in range(1, N - 1):
        peak = max(peak, abs(px[k]))
        dz = max(dz, abs(pz[k] - px[k]))
        dy = max(dy, abs(py[k] - px[k]))
        var yy = Real(k) - Real(N - 1) * 0.5
        var ua = F * (hw * hw - yy * yy) / (2 * NU)
        wx = max(wx, abs(px[k] - ua))
        wy = max(wy, abs(py[k] - ua))
        wz = max(wz, abs(pz[k] - ua))
    var umax = F * hw * hw / (2 * NU)
    print("  channel profiles vs the parabola (umax", umax, "): x", wx / umax, " y", wy / umax, " z", wz / umax, ";  y / z vs x", dy / peak, dz / peak)
    s.check(wx < 0.01 * umax and wz < 0.01 * umax and dz < 2e-3 * peak, "driven along z: the Poiseuille parabola, as along x")
    s.check(wy < 0.01 * umax and dy < 2e-3 * peak, "driven along y (walls in x): the same")

    var box = Lbm(8, 8, 8, NU, BC_PERIODIC)
    box.init_uniform(1.0, 0, 0, 0)
    box.force_z = F
    for _ in range(200):
        box.step()
    var uz = Real(0)
    var rho = Real(0)
    for c in range(box.cells()):
        uz += box.velocity(c)[2] * box.density(c)
        rho += box.density(c)
    var mean = uz / rho
    print("  open box, 200 steps along z: mean uz", mean, " want", 200 * F)
    s.check(abs(mean / (200 * F) - 1) < 1e-3, "an open box gains F per cell per step")

    var a = Lbm(6, 6, 6, NU, BC_PERIODIC)
    var b = Lbm(6, 6, 6, NU, BC_PERIODIC)
    a.init_uniform(1.0, 0.01, 0, 0)
    b.init_uniform(1.0, 0.01, 0, 0)
    a.force_x = F
    b.force_x = F
    for _ in range(50):
        a.step()
        b.step()
    var same = True
    for i in range(len(a.f)):
        same = same and a.f[i] == b.f[i]
    s.check(same, "y / z force zero: deterministic x-only lattice")
    s.finish()
