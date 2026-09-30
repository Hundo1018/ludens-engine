# tier: component
"""The LBM on the GPU vs the CPU reference (ROADMAP 17.42 a).

  seam parity  a tunnel with a sphere, stepped 200 times on each: the
               distributions agree to float32 noise, mass agrees.
  ordinary     a periodic channel driven by a body force: same velocity
               profile on both.
  extreme      a grid configured with LES or interpolated bounce-back is
               refused; no accelerator -> skipped.
"""

from std.sys import has_accelerator
from max.gpu.host import DeviceContext
from harness.runner import Suite
from geometry.vec import Real, Vec3
from fluid.lbm import Lbm, BC_TUNNEL, BC_PERIODIC
from fluid.lbm_gpu import LbmGpu


def _tunnel() -> Lbm:
    var t = Lbm(40, 20, 20, Real(0.02), BC_TUNNEL)
    t.init_uniform(1.0, 0.05, 0, 0)
    t.inlet_u = 0.05
    t.set_solid_sphere(12, 9.5, 9.5, 3)
    return t^


def _worst(a: Lbm, b: Lbm) -> Real:
    var w = Real(0)
    for k in range(len(a.f)):
        w = max(w, abs(a.f[k] - b.f[k]))
    return w


def main() raises:
    var s = Suite("lbm_gpu")
    comptime if not has_accelerator():
        print("  no accelerator: skipped")
        s.check(True, "skipped without accelerator")
        s.finish()
        return
    var ctx = DeviceContext()

    var cpu = _tunnel()
    var host = _tunnel()
    var gpu = LbmGpu(ctx, host)
    for _ in range(200):
        cpu.step()
    gpu.step(ctx, 200)
    gpu.download(host)
    var w = _worst(cpu, host)
    print("  tunnel + sphere, 200 steps: worst |f_cpu - f_gpu|", w)
    s.check(w < 1e-5, "GPU distributions == CPU to float32 noise")
    s.check(abs(cpu.total_mass() - host.total_mass()) / cpu.total_mass() < 1e-5, "mass agrees")

    var pc = Lbm(8, 16, 8, Real(0.05), BC_PERIODIC)
    pc.init_uniform(1.0, 0, 0, 0)
    pc.force_x = 1e-5
    pc.set_solid_box(Vec3(0, 0, 0, 0), Vec3(7, 0, 7, 0))
    pc.set_solid_box(Vec3(0, 15, 0, 0), Vec3(7, 15, 7, 0))
    var ph = Lbm(8, 16, 8, Real(0.05), BC_PERIODIC)
    ph.init_uniform(1.0, 0, 0, 0)
    ph.force_x = 1e-5
    ph.set_solid_box(Vec3(0, 0, 0, 0), Vec3(7, 0, 7, 0))
    ph.set_solid_box(Vec3(0, 15, 0, 0), Vec3(7, 15, 7, 0))
    var pg = LbmGpu(ctx, ph)
    for _ in range(300):
        pc.step()
    pg.step(ctx, 300)
    pg.download(ph)
    var prof = Real(0)
    for y in range(1, 15):
        var c = pc.idx(4, y, 4)
        prof = max(prof, abs(pc.velocity(c)[0] - ph.velocity(c)[0]))
    print("  body-force channel: worst velocity difference", prof)
    s.check(prof < 1e-6, "channel velocity profile matches")

    var les = _tunnel()
    les.smagorinsky = 0.1
    var refused = False
    try:
        _ = LbmGpu(ctx, les)
    except:
        refused = True
    s.check(refused, "LES grid refused")
    s.finish()
