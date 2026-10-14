# tier: integration
"""Physics capture and read-back (ROADMAP 17.80).

  1. Ordinary: a falling stack and a rolling ball recorded for 120 steps
     (keyframe every 30); after `to_bytes` -> `CaptureReader`, every frame's
     bodies equal the live state recorded at that step, bit for bit, and its
     contacts equal the scene's cache; frames can be read in any order.
  2. Integration: `verify` from frame 45 over 60 frames re-simulates from
     the keyframe at 30 and finds no difference; flipping one recorded
     coordinate in frame 70 makes it report 70; a region capture keeps only
     the bodies inside and the contacts touching them, and is smaller.
     Version 2 (delta) frames decode to exactly the version 1 (full) frames
     of the same run, and are smaller once the stack sleeps.
  3. Extreme: bad magic, a truncated file and `key_every` 0 raise; an empty
     scene records frames with no bodies; `verify` before any keyframe raises.
"""

from harness.runner import Suite
from geometry.vec import Real, Vec3
from geometry.aabb import AABB
from physics.rigid6 import QuatBody6, Inertia3
from physics.solver6 import ContactScene6
from physics.solver_config import SolverConfig
from physics.capture import Capture, CaptureReader, CaptureFrame, verify

comptime DT: Real = 1.0 / 60.0
comptime G = Vec3(0, -9.8, 0, 0)


def _scene() -> ContactScene6[QuatBody6]:
    var sc = ContactScene6[QuatBody6]()
    _ = sc.add(QuatBody6.at_rest(Vec3(0, -0.5, 0, 0), Inertia3.box(1, 20, 0.5, 20)), Vec3(20, 0.5, 20, 0), True)
    for k in range(3):
        _ = sc.add(QuatBody6.at_rest(Vec3(0.05 * Real(k), 0.4 + 0.55 * Real(k), 0, 0), Inertia3.box(1, 0.25, 0.25, 0.25)), Vec3(0.25, 0.25, 0.25, 0), False)
    var ball = QuatBody6.at_rest(Vec3(5, 0.3, 0, 0), Inertia3.sphere(1, 0.3))
    ball.vel = Vec3(1, 0, 0, 0)
    _ = sc.add_sphere(ball^, 0.3, False)
    return sc^


def _matches(f: CaptureFrame, sc: ContactScene6[QuatBody6]) -> Bool:
    if len(f.slot) != len(sc.bset.bodies) or len(f.ca) != len(sc.cache):
        return False
    for k in range(len(f.slot)):
        ref b = sc.bset.bodies[f.slot[k]]
        if b.pos != f.pos[k] or b.vel != f.vel[k] or b.omega != f.omega[k] or b.q.w != f.rot[4 * k + 3]:
            return False
        if f.island[k] != sc.bset.island[f.slot[k]]:
            return False
    var p = 0
    for c in range(len(f.ca)):
        ref pr = sc.cache[c]
        if f.ca[c] != pr.a or f.cb[c] != pr.b or f.npts[c] != pr.m.count or f.normal[c] != pr.m.normal:
            return False
        for k in range(pr.m.count):
            if f.point[p] != pr.m.points[k] or f.depth[p] != pr.m.depths[k] or f.impulse[p] != pr.acc[k]:
                return False
            p += 1
    return True


def main() raises:
    var s = Suite("capture")
    var sc = _scene()
    var cap = Capture(30)
    var cfg = SolverConfig()
    for _ in range(120):
        sc.step(DT, G, cfg)
        cap.record(sc)
    var bytes = cap.to_bytes()
    var rd = CaptureReader(bytes)
    print("  120 frames, 4 keyframes:", len(bytes), "bytes (", cap.byte_size() // 120, "per frame incl. keyframes )")
    s.check(rd.frame_count() == 120 and len(rd.keys) == 4, "120 frames, keyframes at 0 / 30 / 60 / 90")

    # replay the same run and compare each frame as it is reached, in reverse order too
    var sc2 = _scene()
    var all_ok = True
    for k in range(120):
        sc2.step(DT, G, cfg)
        if not _matches(rd.frame(k), sc2):
            all_ok = False
    s.check(all_ok, "every frame equals the live state at its step (bodies, islands, contacts)")
    var f119 = rd.frame(119)
    var f3 = rd.frame(3)
    s.check(f119.step_index == sc2.step_index and f3.step_index == f119.step_index - 116, "frames read in any order (step index 119 then 3)")

    # ---- verify ------------------------------------------------------------------
    s.check(verify(rd, 45, 60, DT, G, cfg) == -1, "verify from frame 45 over 60 frames: no divergence")
    # flip one coordinate of frame 70's first changed body (version 2
    # offset: step 8 + full flag 8 + changed count 8 + slot 8 = 32)
    var tampered = cap.frames[70].copy()
    tampered[32] ^= 1
    cap.frames[70] = tampered^
    var rd2 = CaptureReader(cap.to_bytes())
    var at = verify(rd2, 45, 60, DT, G, cfg)
    print("  tampered frame 70: verify reports", at)
    s.check(at == 70, "a flipped bit in frame 70 is found at 70")

    # ---- delta (version 2) vs full frames (version 1) ---------------------------------
    var s1 = _scene()
    var c1 = Capture(30, False)
    var s3 = _scene()
    var c3 = Capture(30)
    for _ in range(240):
        s1.step(DT, G, cfg)
        c1.record(s1)
        s3.step(DT, G, cfg)
        c3.record(s3)
    var r1 = CaptureReader(c1.to_bytes())
    var r3 = CaptureReader(c3.to_bytes())
    var same = r1.version == 1 and r3.version == 2
    for k in range(240):
        var a = r1.frame(k)
        var b = r3.frame(k)
        if a.slot != b.slot or a.pos != b.pos or a.rot != b.rot or a.vel != b.vel or a.sleeping != b.sleeping or a.island != b.island:
            same = False
        if a.ca != b.ca or a.cb != b.cb or a.normal != b.normal or a.npts != b.npts or a.point != b.point or a.depth != b.depth or a.impulse != b.impulse:
            same = False
    var fb1 = 0
    var fb3 = 0
    for k in range(180, 240):
        fb1 += len(c1.frames[k])
        fb3 += len(c3.frames[k])
    print("  240 frames: version 1", c1.byte_size(), "bytes, version 2 (delta)", c3.byte_size(), "; frames 180-239 (stack asleep):", fb1, "vs", fb3, "bytes")
    s.check(same, "delta frames decode to the full frames, every field, all 240")
    s.check(fb3 * 3 < fb1, "with the stack asleep the delta frames are under a third of the full ones (the ball still rolls)")

    # ---- region ----------------------------------------------------------------------
    var sr = _scene()
    var cr = Capture(30)
    cr.set_region(AABB[3](Vec3(-1, 0, -1, 0), Vec3(1, 3, 1, 0)))
    for _ in range(60):
        sr.step(DT, G, cfg)
        cr.record(sr)
    var rr = CaptureReader(cr.to_bytes())
    var fr = rr.frame(59)
    var only_stack = len(fr.slot) == 3 and fr.body_index(4) == -1 and fr.body_index(0) == -1
    var touching = True
    for c in range(len(fr.ca)):
        if fr.body_index(fr.ca[c]) < 0 and fr.body_index(fr.cb[c]) < 0:
            touching = False
    var full_frame = len(cap.frames[59])
    print("  region capture: bodies", len(fr.slot), " contacts", len(fr.ca), " frame bytes", len(cr.frames[59]), "vs", full_frame)
    s.check(only_stack and touching and len(cr.frames[59]) < full_frame, "region keeps the stack's 3 bodies and their contacts only")

    # ---- extremes ------------------------------------------------------------------------
    var raised = 0
    var bad = bytes.copy()
    bad[0] = 0
    try:
        _ = CaptureReader(bad)
    except:
        raised += 1
    var cut = List[UInt8]()
    for q in range(len(bytes) // 2):
        cut.append(bytes[q])
    try:
        _ = CaptureReader(cut)
    except:
        raised += 1
    try:
        _ = Capture(0)
    except:
        raised += 1
    s.check(raised == 3, "bad magic, truncation and key_every 0 raise")
    var se = ContactScene6[QuatBody6]()
    var ce = Capture(2)
    se.step(DT, G, cfg)
    ce.record(se)
    var re = CaptureReader(ce.to_bytes())
    s.check(len(re.frame(0).slot) == 0, "empty scene: a frame with no bodies")
    var nk = Capture(1000)
    var sn = _scene()
    sn.step(DT, G, cfg)
    nk.record(sn)
    nk.key_frame = List[Int]()
    nk.keys = List[List[UInt8]]()
    var rn = CaptureReader(nk.to_bytes())
    var r2 = False
    try:
        _ = verify(rn, 0, 1, DT, G, cfg)
    except:
        r2 = True
    s.check(r2, "verify with no keyframe raises")
    s.finish()
