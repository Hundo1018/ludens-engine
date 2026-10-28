# tier: integration
"""Rollback netcode and the prediction-strategy seam (ROADMAP 17.16).

Parity: three players drive `ArenaSim` (boxes on a walled floor with
crates) from scripted inputs over deterministic links with latency, jitter
and 10 % loss. Lockstep peers, rollback peers, and a snapshot server with
three clients all end at tick 240 with the world hash of applying the same
inputs offline -- bit for bit. Rollback peers really roll back (mispredicted
inputs, re-simulated ticks counted) and never predict past their ring.
Desync: a peer whose simulation differs (one crate moved) is reported by the
hash exchange. Bandwidth: delta snapshots are smaller than full ones.
Extremes: a 2-tick rollback ring under 8 ticks of latency still converges
(stalls instead of over-predicting), input validation rejects spoofed /
stale / far-ahead / conflicting inputs, implausible motion is flagged, the
delta codec round-trips, messages survive truncation checks, lag
compensation hits where the shooter saw the target 7 ticks ago.
"""

from harness.runner import Suite
from std.math import sin
from geometry.vec import Real, Vec3
from physics.rigid6 import Inertia3, QuatBody6
from collision.world_query import QueryFilter
from gameplay.netcode import (
    PlayerInput,
    InputLog,
    ArenaSim,
    NetSim,
    NetPeer,
    LockstepPeer,
    RollbackPeer,
    SnapshotServer,
    SnapshotClient,
    SimLink,
    InputValidator,
    motion_plausible,
    delta_encode,
    delta_decode,
    run_offline,
    decode_inputs,
    PoseRing,
    rewind_ray_cast,
    INPUT_OK,
    INPUT_BAD_PLAYER,
    INPUT_TOO_OLD,
    INPUT_TOO_FAR_AHEAD,
    INPUT_CONFLICT,
)

comptime T = 240
comptime NP = 3


def script(p: Int, t: Int) -> PlayerInput:
    var a = Real(t) * 0.05 + Real(p) * 2.1
    var mx = Int(sin(a) * 120)
    var mz = Int(sin(a * 0.7 + 1) * 120)
    var b = UInt8(1) if (t + p * 13) % 50 == 0 else UInt8(0)
    return PlayerInput(t, p, Int8(mx), Int8(mz), b)


def reference() raises -> UInt64:
    var sim = ArenaSim(NP, 6)
    var log = InputLog(NP)
    for t in range(T):
        for p in range(NP):
            _ = log.put(script(p, t))
    run_offline(sim, log, T)
    return sim.hash()


def links(lat: Int, jit: Int, loss: Real, seed: UInt64) -> List[SimLink]:
    """Directed links, index from * NP + to."""
    var out = List[SimLink]()
    for k in range(NP * NP):
        out.append(SimLink(lat, jit, loss, seed + UInt64(k) * 7919))
    return out^


def exchange[P: NetPeer](mut a: P, mut b: P, mut c: P, mut ls: List[SimLink], f: Int) raises:
    for src in range(NP):
        for dst in range(NP):
            if src == dst:
                continue
            var msg: List[UInt8]
            match src:
                case 0:
                    msg = a.outgoing(dst)
                case 1:
                    msg = b.outgoing(dst)
                case _:
                    msg = c.outgoing(dst)
            ls[src * NP + dst].send(f, msg^)
    for src in range(NP):
        for dst in range(NP):
            if src == dst:
                continue
            var got = ls[src * NP + dst].deliver(f)
            for m in got:
                match dst:
                    case 0:
                        a.receive(src, m)
                    case 1:
                        b.receive(src, m)
                    case _:
                        c.receive(src, m)


def run_mesh[P: NetPeer](mut a: P, mut b: P, mut c: P, mut ls: List[SimLink]) raises -> Int:
    """Frames until every peer reached T (or a cap); returns the frame count."""
    var f = 0
    while f < T + 400:
        if f < T:
            a.submit(script(0, f))
            b.submit(script(1, f))
            c.submit(script(2, f))
        exchange(a, b, c, ls, f)
        var target = min(f + 1, T)
        a.update(target)
        b.update(target)
        c.update(target)
        if f >= T and a.sim_tick() == T and b.sim_tick() == T and c.sim_tick() == T:
            # keep exchanging a few more frames so late corrections land
            if f >= T + 40:
                return f
        f += 1
    return f


def main() raises:
    var s = Suite("netcode")
    var ref_hash = reference()

    # ---- input encoding ----
    var buf = List[UInt8]()
    PlayerInput(123456, 2, -127, 99, 5).encode(buf)
    var pos = 0
    var back = PlayerInput.decode(buf, pos)
    s.check(back == PlayerInput(123456, 2, -127, 99, 5) and pos == 12, "PlayerInput round-trips in 12 bytes")

    # ---- lockstep ----
    var l0 = LockstepPeer[ArenaSim](ArenaSim(NP, 6), 0)
    var l1 = LockstepPeer[ArenaSim](ArenaSim(NP, 6), 1)
    var l2 = LockstepPeer[ArenaSim](ArenaSim(NP, 6), 2)
    var ll = links(4, 3, 0.1, 11)
    _ = run_mesh(l0, l1, l2, ll)
    s.check(l0.sim_tick() == T and l0.world_hash() == ref_hash and l1.world_hash() == ref_hash and l2.world_hash() == ref_hash, "lockstep: all peers == offline reference")
    s.check(l0.stalls > 0, "lockstep waited on the network (" + String(l0.stalls) + " stalls)")
    s.check(l0.desync_tick < 0 and l1.desync_tick < 0, "lockstep: no desync reported")

    # ---- rollback ----
    var r0 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 0, 12)
    var r1 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 1, 12)
    var r2 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 2, 12)
    var rl = links(4, 3, 0.1, 22)
    _ = run_mesh(r0, r1, r2, rl)
    s.check(r0.world_hash() == ref_hash and r1.world_hash() == ref_hash and r2.world_hash() == ref_hash, "rollback: all peers == offline reference")
    s.check(r0.rollbacks > 0 and r0.resim_ticks > 0, "rollback really rolled back (" + String(r0.rollbacks) + " rollbacks, " + String(r0.resim_ticks) + " re-simulated ticks)")
    s.eqi(r0.too_deep + r1.too_deep + r2.too_deep, 0, "never rolled back past the ring")
    s.check(r0.desync_tick < 0 and r1.desync_tick < 0 and r2.desync_tick < 0, "rollback: hashes agree")
    s.check(r0.hashes.newest >= T - 1, "final hashes recorded up to the last tick")
    print("  netcode: rollback peer 0", r0.rollbacks, "rollbacks,", r0.resim_ticks, "re-simulated ticks,", r0.mispredicted, "mispredicted inputs")

    # tiny ring, long latency: stalls rather than over-predicting, still exact
    var t0 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 0, 2)
    var t1 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 1, 2)
    var t2 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 2, 2)
    var tl = links(8, 0, 0.0, 33)
    _ = run_mesh(t0, t1, t2, tl)
    s.check(t0.world_hash() == ref_hash and t1.world_hash() == ref_hash, "2-tick ring under 8 ticks of latency: still exact")
    s.eqi(t0.too_deep, 0, "and never too deep")

    # ---- desync detection ----
    var crate = len(ArenaSim(NP, 6).scene.bset.bodies) - 1
    var d0 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 0, 12)
    var d1 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 1, 12)
    var d2sim = ArenaSim(NP, 6)
    d2sim.scene.set_velocity(d2sim.scene.bset.id_of(crate), Vec3(3, 0, 0, 0), Vec3(0, 0, 0, 0))
    var d2 = RollbackPeer[ArenaSim](d2sim^, 2, 12)
    var dl = links(2, 1, 0.0, 44)
    _ = run_mesh(d0, d1, d2, dl)
    s.check(d0.desync_tick >= 0 or d1.desync_tick >= 0 or d2.desync_tick >= 0, "a diverged peer is reported by the hash exchange")
    s.check(d2.world_hash() != ref_hash, "(and it really diverged)")

    # ---- snapshot server + clients (star) ----
    var srv = SnapshotServer[ArenaSim](ArenaSim(NP, 6), 3)
    var c0 = SnapshotClient[ArenaSim](ArenaSim(NP, 6), 0)
    var c1 = SnapshotClient[ArenaSim](ArenaSim(NP, 6), 1)
    var c2 = SnapshotClient[ArenaSim](ArenaSim(NP, 6), 2)
    var up = links(3, 2, 0.1, 55)  # client p -> server at [p]
    var down = links(3, 2, 0.1, 66)  # server -> client p at [p]
    var f = 0
    while f < T + 400:
        if f < T:
            c0.submit(script(0, f))
            c1.submit(script(1, f))
            c2.submit(script(2, f))
        up[0].send(f, c0.outgoing(NP))
        up[1].send(f, c1.outgoing(NP))
        up[2].send(f, c2.outgoing(NP))
        for p in range(NP):
            for m in up[p].deliver(f):
                srv.receive(p, m)
        srv.update(min(f + 1, T))
        for p in range(NP):
            down[p].send(f, srv.outgoing(p))
        for m in down[0].deliver(f):
            c0.receive(NP, m)
        for m in down[1].deliver(f):
            c1.receive(NP, m)
        for m in down[2].deliver(f):
            c2.receive(NP, m)
        if c0.newest == T and c1.newest == T and c2.newest == T:
            break
        f += 1
    s.check(srv.world_hash() == ref_hash, "snapshot server == offline reference")
    s.check(c0.world_hash() == ref_hash and c1.world_hash() == ref_hash and c2.world_hash() == ref_hash, "every client shows the server's final world")
    var full = len(srv.sim.save())
    var per_msg = srv.bytes_out // max(1, f)
    s.check(per_msg * 2 < full * NP, "delta snapshots: " + String(per_msg) + " bytes / frame to 3 clients vs " + String(full) + " bytes per full snapshot")
    print("  netcode: snapshot", full, "bytes full,", per_msg, "bytes per frame to all clients (delta), frames", f)

    # ---- validation ----
    var v = InputValidator(NP, 10, 20)
    var vlog = InputLog(NP)
    _ = vlog.put(PlayerInput(50, 1, 10, 0, 0))
    s.eqi(v.check(PlayerInput(50, 1, 10, 0, 0), 1, 50, vlog), INPUT_OK, "valid input")
    s.eqi(v.check(PlayerInput(50, 2, 10, 0, 0), 1, 50, vlog), INPUT_BAD_PLAYER, "player 1 cannot send player 2's input")
    s.eqi(v.check(PlayerInput(30, 1, 10, 0, 0), 1, 50, vlog), INPUT_TOO_OLD, "older than the window")
    s.eqi(v.check(PlayerInput(90, 1, 10, 0, 0), 1, 50, vlog), INPUT_TOO_FAR_AHEAD, "too far ahead")
    s.eqi(v.check(PlayerInput(50, 1, -10, 0, 0), 1, 50, vlog), INPUT_CONFLICT, "contradicts the input already received")
    s.check(motion_plausible(Vec3(0, 0, 0, 0), Vec3(0.08, 0, 0, 0), 1, 1.0 / 60.0, 5), "5 m/s for one tick is plausible")
    s.check(not motion_plausible(Vec3(0, 0, 0, 0), Vec3(0.3, 0, 0, 0), 1, 1.0 / 60.0, 5), "18 m/s against a 5 m/s cap is flagged")

    # ---- delta codec ----
    var base = List[UInt8]()
    var cur = List[UInt8]()
    for i in range(1000):
        base.append(UInt8(i % 251))
        cur.append(UInt8(i % 251) if i % 97 != 0 else UInt8(7))
    var enc = delta_encode(cur, base)
    var p2 = 0
    var dec = delta_decode(enc, p2, base)
    var same = len(dec) == len(cur)
    for i in range(len(cur)):
        if same and dec[i] != cur[i]:
            same = False
    s.check(same and len(enc) < 100, "delta round-trips; 11 changed bytes of 1000 encode to " + String(len(enc)))
    var raised = False
    try:
        var short = List[UInt8]()
        short.append(1)
        _ = decode_inputs(short)
    except:
        raised = True
    s.check(raised, "truncated message raises")

    # ---- lag compensation ----
    var arena = ArenaSim(1, 0)
    var ring = PoseRing(16)
    var target_body = arena.body_of[0]
    var history = List[Vec3]()
    for t in range(30):
        var ins = List[PlayerInput]()
        ins.append(PlayerInput(t, 0, 127, 0, 0))  # running +x at 5 m/s
        arena.step(ins)
        ring.record(arena.tick(), arena.scene.query_poses())
        history.append(arena.scene.bset.bodies[target_body].position())
    # the shooter saw tick 23 (7 ticks of latency) and aimed at the target then
    var seen = history[22]
    var origin = Vec3(seen[0], seen[1], 0.5, 0)
    var dir = Vec3(0, 0, 1, 0)
    var now_hit = arena.scene.ray_cast(origin, dir, 10, QueryFilter.all())
    var past_hit = rewind_ray_cast(arena.scene, ring, 23, origin, dir, 10, QueryFilter.all())
    s.check(not (now_hit.hit and now_hit.body == target_body), "against the present the shot misses (the target moved 0.6 m)")
    s.check(past_hit.hit and past_hit.body == target_body, "rewound to the tick the shooter saw: hit")
    raised = False
    try:
        _ = rewind_ray_cast(arena.scene, ring, 2, origin, dir, 10, QueryFilter.all())
    except:
        raised = True
    s.check(raised, "a tick older than the ring raises")
    s.finish()
