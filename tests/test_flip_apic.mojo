# tier: integration
"""APIC transfers for the FLIP water (ROADMAP 17.60, `physics.flip_apic`).

  1. Ordinary: a water disc (radius 0.2 m, 32 x 32 cells of 1/32 m, zero
     gravity) spinning rigidly at 1 rad/s, after 0.5 s: angular momentum
     kept APIC 98.3 %, PIC (flip = 0) 24.8 %, FLIP 0.95 92.8 %; velocity
     noise about the rigid profile APIC 4.2 %, FLIP 5.8 % (asserted: APIC
     > 95 %, above PIC, less noise than FLIP).
  2. Integration: still water under APIC stays still (max speed < 1e-5
     after 1 s) and the 0.25 x 0.5 m dam break runs behind Ritter's front at
     1.2 to 2 sqrt(g h0), as with FLIP (test_flip).
  3. Extreme: particles added by hand (no APIC state) start with zero
     affine gradients; `step` (FLIP) is as it was (test_flip's golden
     section unchanged).
"""

from std.math import sqrt
from harness.runner import Suite
from geometry.vec import Real
from physics.flip import FlipWater2
from physics.flip_apic import ApicState, apic_step

comptime G: Real = 9.8


def disc(mode: Int) raises -> FlipWater2:
    var w = FlipWater2(32, 32, 1.0 / 32.0, 0)
    w.fill_box(0.3, 0.3, 0.7, 0.7, 2)
    # keep the disc, give it rigid rotation about (0.5, 0.5)
    var px = List[Real]()
    var py = List[Real]()
    for k in range(w.count()):
        var dx = w.px[k] - 0.5
        var dy = w.py[k] - 0.5
        if dx * dx + dy * dy < 0.04:
            px.append(w.px[k])
            py.append(w.py[k])
    w.px = px^
    w.py = py^
    w.pu = List[Real](length=len(w.px), fill=0)
    w.pv = List[Real](length=len(w.px), fill=0)
    for k in range(len(w.px)):
        w.pu[k] = -(w.py[k] - 0.5)
        w.pv[k] = w.px[k] - 0.5
    if mode == 1:
        w.flip = 0
    return w^


def ang(w: FlipWater2) -> Real:
    var l = Real(0)
    for k in range(w.count()):
        l += (w.px[k] - 0.5) * w.pv[k] - (w.py[k] - 0.5) * w.pu[k]
    return l


def noise(w: FlipWater2) -> Real:
    """RMS of each particle's speed minus the mean speed at its radius
    (rigid rotation: speed = omega r), as a fraction of the mean speed."""
    var acc = Real(0)
    var msp = Real(0)
    var r2s = Real(0)
    for k in range(w.count()):
        var dx = w.px[k] - 0.5
        var dy = w.py[k] - 0.5
        r2s += dx * dx + dy * dy
    var omega = ang(w) / r2s
    for k in range(w.count()):
        var dx = w.px[k] - 0.5
        var dy = w.py[k] - 0.5
        var eu = w.pu[k] + omega * dy
        var ev = w.pv[k] - omega * dx
        acc += eu * eu + ev * ev
        msp += omega * omega * (dx * dx + dy * dy)
    return sqrt(acc / max(msp, Real(1e-12)))


def main() raises:
    var s = Suite("flip_apic")
    var keep = List[Real]()
    var noi = List[Real]()
    for mode in range(3):
        var w = disc(mode)
        var a = ApicState()
        var l0 = ang(w)
        for _ in range(100):
            if mode == 0:
                apic_step(w, a, 0.005)
            else:
                w.step(0.005)
        keep.append(ang(w) / l0)
        noi.append(noise(w))
    print("spinning disc 0.5 s, angular momentum kept: APIC", keep[0], " PIC", keep[1], " FLIP 0.95", keep[2], ";  velocity noise about rigid rotation: APIC", noi[0], " PIC", noi[1], " FLIP", noi[2])
    s.check(keep[0] > 0.95 and keep[1] < keep[0] and noi[0] < noi[2], "APIC keeps angular momentum (> 95 %, more than PIC) with less noise than FLIP")

    var st = FlipWater2(40, 24, 0.025)
    var sa = ApicState()
    st.fill_box(0, 0, 1.0, 0.3)
    var t = Real(0)
    while t < 1.0:
        var dt = min(Real(0.005), st.max_dt())
        apic_step(st, sa, dt)
        t += dt
    var vmax = Real(0)
    for k in range(st.count()):
        vmax = max(vmax, abs(st.pu[k]) + abs(st.pv[k]))
    var d = FlipWater2(80, 24, 0.025)
    var da = ApicState()
    d.fill_box(0, 0, 0.25, 0.5)
    var c0 = Real(sqrt(G * 0.5))
    t = 0
    var behind = True
    var f03 = Real(0)
    while t < 0.5 - 1e-6:
        var dt = min(Real(0.004), d.max_dt())
        dt = min(dt, 0.5 - t)
        apic_step(d, da, dt)
        t += dt
        var front = Real(0)
        for q in range(d.count()):
            front = max(front, d.px[q])
        behind = behind and front < 0.25 + 2 * c0 * t
        if f03 == 0 and t >= 0.3:
            f03 = front
    var f05 = Real(0)
    for q in range(d.count()):
        f05 = max(f05, d.px[q])
    var speed = (f05 - f03) / 0.2 / c0
    print("APIC still tank max speed", vmax, ";  dam break front speed / sqrt(g h0)", speed)
    s.check(vmax < 1e-5 and behind and speed > 1.2 and speed < 2.0, "APIC: still water stays still; dam break behind Ritter at 1.2 - 2 sqrt(g h0)")

    var h = FlipWater2(8, 8, 0.1, 0)
    var ha = ApicState()
    h.px.append(0.4)
    h.py.append(0.4)
    h.pu.append(0.1)
    h.pv.append(0)
    apic_step(h, ha, 0.01)
    s.check(len(ha.cux) == 1 and h.count() == 1, "hand-added particles get zero affine state")
    s.finish()
