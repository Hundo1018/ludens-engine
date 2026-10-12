# tier: integration
"""GPU articulations (ROADMAP 17.17): device vs host run of the same kernel body.

512 instances of a 5-link Y-tree, each from its own state, 120 steps of
1/240 s fused into launches of 30 steps. The host reference is
`ArticBatch.step_host` (which `test_artic_batch` ties to `Chain`); the
device run must match it within float-contraction noise. No accelerator ->
the device half is skipped (the host half still runs).
"""

from std.sys import has_accelerator
from std.math import sin, cos
from harness.runner import Suite
from geometry.vec import Real, Vec3
from physics.chain import Chain, ChainLink
from physics.artic_batch import ArticBatch
from physics.gpu_artic import GpuArticBatch
from max.gpu.host import DeviceContext

comptime G = Vec3(0, -9.8, 0, 0)
comptime N = 512
comptime STEPS = 120
comptime FUSE = 30
comptime DT: Real = 1.0 / 240.0


def _v(x: Real, y: Real, z: Real) -> Vec3:
    return Vec3(x, y, z, 0)


def ytree() raises -> Chain:
    var c = Chain()
    c.add_link(ChainLink.revolute(_v(0, 0, 1), _v(0, 0, 0), _v(0, -0.3, 0), 1.5, _v(0.03, 0.01, 0.03)))
    var l = c.add_link_to(0, ChainLink.revolute(_v(1, 0, 0), _v(-0.2, -0.6, 0), _v(0, -0.25, 0), 0.8, _v(0.02, 0.01, 0.02)))
    var r = c.add_link_to(0, ChainLink.prismatic(_v(0, -1, 0), _v(0.2, -0.6, 0), _v(0, -0.1, 0), 0.9, _v(0.02, 0.01, 0.02)))
    _ = c.add_link_to(l, ChainLink.revolute(_v(0, 1, 0), _v(0, -0.5, 0), _v(0.03, -0.2, 0), 0.5, _v(0.01, 0.005, 0.01)))
    _ = c.add_link_to(r, ChainLink.revolute(_v(1, 0, 0), _v(0, -0.5, 0), _v(0, -0.2, 0.04), 0.5, _v(0.01, 0.005, 0.01)))
    return c^


def seeded() raises -> ArticBatch:
    var b = ArticBatch(ytree(), N)
    for k in range(N):
        for i in range(5):
            b.set_q(k, i, 0.3 * sin(Real(k * 5 + i)))
            b.set_qd(k, i, 0.5 * cos(Real(k * 3 + 2 * i)))
            b.set_tau(k, i, 0.2 * sin(Real(k + 7 * i)))
    return b^


def main() raises:
    var s = Suite("gpu_artic")
    var host = seeded()
    for _ in range(STEPS):
        host.step_host(DT, G)
    var finite = True
    for v in host.state:
        if v != v:
            finite = False
    s.check(finite, "host reference stays finite over " + String(STEPS) + " steps x " + String(N) + " instances")

    comptime if has_accelerator():
        var ctx = DeviceContext()  # the test is the single owner (F17)
        var dev = seeded()
        var g = GpuArticBatch(ctx, dev)
        for _ in range(STEPS // FUSE):
            g.step(ctx, FUSE, DT, G)
        g.download(ctx, dev)
        var worst = Float64(0)
        for i in range(len(dev.state)):
            worst = max(worst, abs(Float64(dev.state[i] - host.state[i])))
        print("  max |device - host| over q, qd, tau:", worst)
        s.check(worst < 1e-3, "device == host kernel body (float-contraction noise only)")
    else:
        print("  (no GPU on this host: device half skipped)")
    s.finish()
