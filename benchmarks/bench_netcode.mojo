"""Rollback netcode (ROADMAP 17.16): the prediction-strategy seam.

Three players, `ArenaSim` with 6 crates, 240 ticks of scripted input, links
with 2 or 6 ticks of one-way latency, 2 ticks of jitter and 5 % loss.
Per strategy: wall time per frame for the whole session (all peers), bytes
sent per frame, and in the label how far behind the newest submitted input
each peer's displayed world is on average (lockstep waits for the slowest
input; rollback shows the present and pays in re-simulation; snapshot
clients show the server's past) plus rollbacks / re-simulated ticks.

Run: pixi run mojo run -I build benchmarks/bench_netcode.mojo
"""

from std.math import sin
from harness.bench import BenchTable, now
from geometry.vec import Real
from gameplay.netcode import (
    PlayerInput,
    ArenaSim,
    NetPeer,
    LockstepPeer,
    RollbackPeer,
    SnapshotServer,
    SnapshotClient,
    SimLink,
)

comptime T = 240
comptime NP = 3


def script(p: Int, t: Int) -> PlayerInput:
    var a = Real(t) * 0.05 + Real(p) * 2.1
    return PlayerInput(t, p, Int8(Int(sin(a) * 120)), Int8(Int(sin(a * 0.7 + 1) * 120)), UInt8(1) if (t + p * 13) % 50 == 0 else UInt8(0))


def links(lat: Int, seed: UInt64) -> List[SimLink]:
    var out = List[SimLink]()
    for k in range(NP * NP):
        out.append(SimLink(lat, 2, 0.05, seed + UInt64(k) * 7919))
    return out^


def mesh[P: NetPeer](mut a: P, mut b: P, mut c: P, lat: Int, mut behind: Int, mut frames: Int) raises -> Int:
    var ls = links(lat, 99)
    var f = 0
    behind = 0
    while f < T + 200:
        if f < T:
            a.submit(script(0, f))
            b.submit(script(1, f))
            c.submit(script(2, f))
        for src in range(NP):
            for dst in range(NP):
                if src != dst:
                    var m = a.outgoing(dst) if src == 0 else (b.outgoing(dst) if src == 1 else c.outgoing(dst))
                    ls[src * NP + dst].send(f, m^)
        for src in range(NP):
            for dst in range(NP):
                if src != dst:
                    for m in ls[src * NP + dst].deliver(f):
                        if dst == 0:
                            a.receive(src, m)
                        elif dst == 1:
                            b.receive(src, m)
                        else:
                            c.receive(src, m)
        var target = min(f + 1, T)
        a.update(target)
        b.update(target)
        c.update(target)
        if f < T:
            behind += (target - a.sim_tick()) + (target - b.sim_tick()) + (target - c.sim_tick())
        f += 1
        if f > T and a.sim_tick() == T and b.sim_tick() == T and c.sim_tick() == T:
            break
    frames = f
    var bytes = 0
    for k in range(len(ls)):
        bytes += ls[k].sent_bytes
    return bytes


def main() raises:
    var t = BenchTable("Netcode strategies (17.16): 3 players, 240 ticks, 2 ticks jitter, 5 % loss")
    for lat in [2, 6]:
        var behind = 0
        var frames = 0
        var l0 = LockstepPeer[ArenaSim](ArenaSim(NP, 6), 0)
        var l1 = LockstepPeer[ArenaSim](ArenaSim(NP, 6), 1)
        var l2 = LockstepPeer[ArenaSim](ArenaSim(NP, 6), 2)
        var t0 = now()
        var bytes = mesh(l0, l1, l2, lat, behind, frames)
        var label = "Lockstep, latency " + String(lat) + " (behind " + String(Int(Real(behind) / Real(3 * T) * 10) / 10) + " ticks, " + String(bytes // frames) + " B / frame)"
        t.add(label, NP, "frame", now() - t0, frames)

        var r0 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 0, 12)
        var r1 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 1, 12)
        var r2 = RollbackPeer[ArenaSim](ArenaSim(NP, 6), 2, 12)
        t0 = now()
        bytes = mesh(r0, r1, r2, lat, behind, frames)
        label = "Rollback ring 12, latency " + String(lat) + " (behind " + String(Int(Real(behind) / Real(3 * T) * 10) / 10)
        label += " ticks, " + String(r0.rollbacks + r1.rollbacks + r2.rollbacks) + " rollbacks, "
        label += String(r0.resim_ticks + r1.resim_ticks + r2.resim_ticks) + " re-simulated ticks, " + String(bytes // frames) + " B / frame)"
        t.add(label, NP, "frame", now() - t0, frames)

        var srv = SnapshotServer[ArenaSim](ArenaSim(NP, 6), 3)
        var c0 = SnapshotClient[ArenaSim](ArenaSim(NP, 6), 0)
        var c1 = SnapshotClient[ArenaSim](ArenaSim(NP, 6), 1)
        var c2 = SnapshotClient[ArenaSim](ArenaSim(NP, 6), 2)
        var up = links(lat, 7)
        var down = links(lat, 8)
        var f = 0
        var lag = 0
        t0 = now()
        while f < T + 200:
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
            if f < T:
                lag += (f + 1 - max(c0.newest, 0)) + (f + 1 - max(c1.newest, 0)) + (f + 1 - max(c2.newest, 0))
            f += 1
            if c0.newest == T and c1.newest == T and c2.newest == T:
                break
        var sb = 0
        for k in range(NP):
            sb += up[k].sent_bytes + down[k].sent_bytes
        label = "Snapshot interp, every 3 ticks, latency " + String(lat) + " (behind " + String(Int(Real(lag) / Real(3 * T) * 10) / 10)
        label += " ticks, " + String(sb // f) + " B / frame, full snapshot " + String(len(srv.sim.save())) + " B)"
        t.add(label, NP, "frame", now() - t0, f)
    t.print_report()
