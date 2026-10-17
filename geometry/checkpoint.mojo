"""Checkpointed reverse-mode gradients (ROADMAP 17.84).

A `Tape` holds one node per operation, so the gradient of a T-step rollout
costs memory proportional to T. `grad_checkpointed` keeps only the state
every `every` steps (the checkpoints) during the forward pass; the backward
pass then walks the segments from last to first, re-running each from its
checkpoint on a fresh tape and sweeping it with the adjoints the later
segments produced:

  * the segment's output state nodes start with the adjoint of the next
    segment's input state;
  * the parameter input nodes start with the parameter adjoint accumulated
    so far (a running sum, not a per-segment total added afterwards).

The re-run computes the same primal values (the same operations on the
same inputs) and the sweep visits the same partials in the same order as
`grad_full`'s single sweep, so the two gradients are equal bit for bit;
only the peak tape length changes (one segment instead of the whole
rollout). The cost is one extra forward pass. (Revolve, Griewank & Walther
2000, places checkpoints optimally for a memory budget; this uses a fixed
stride.)

A system is a `RevSystem`: a state vector advanced by `step` under
parameters, and a scalar `loss` of the final state.
"""

from std.memory import alloc, Layout
from .vec import Real
from .field import Tape, TapePtr, RevReal


trait RevSystem:
    def state_dim(self) -> Int: ...

    def param_dim(self) -> Int: ...

    def step(self, mut state: List[RevReal], params: List[RevReal]): ...

    def loss(self, state: List[RevReal]) -> RevReal: ...


@fieldwise_init
struct RevGrad(Copyable, Movable):
    var loss: Real
    var d_params: List[Real]
    var d_state0: List[Real]
    var peak_nodes: Int  # longest tape held at once


def _seed_all(t: TapePtr, vals: List[Real]) -> List[RevReal]:
    var out = List[RevReal](capacity=len(vals))
    for v in vals:
        out.append(RevReal.seed(t, v))
    return out^


def _values(xs: List[RevReal]) -> List[Real]:
    var out = List[Real](capacity=len(xs))
    for x in xs:
        out.append(x.v)
    return out^


def _sweep(t: Tape, mut adj: List[Real]):
    """Backward sweep with the given starting adjoints (one per node)."""
    var k = len(t.nodes) - 1
    while k >= 0:
        var a = adj[k]
        if a != 0:
            var nd = t.nodes[k]
            if nd.l >= 0:
                adj[nd.l] += nd.dl * a
            if nd.r >= 0:
                adj[nd.r] += nd.dr * a
        k -= 1


def _new_tape() -> TapePtr:
    var p = alloc[Tape](Layout[Tape](count=1)).unsafe_leak()
    p.unsafe_write(Tape())
    return p


def _free_tape(p: TapePtr):
    p.unsafe_deinit_pointee()
    p.unsafe_free()


def grad_full[S: RevSystem](sys: S, x0: List[Real], params: List[Real], steps: Int) -> RevGrad:
    """Gradient of `loss(state after steps)` with one tape for the whole
    rollout."""
    var t = _new_tape()
    var p = _seed_all(t, params)
    var x = _seed_all(t, x0)
    var pi = List[Int]()
    var xi = List[Int]()
    for v in p:
        pi.append(v.idx)
    for v in x:
        xi.append(v.idx)
    for _ in range(steps):
        sys.step(x, p)
    var l = sys.loss(x)
    var adj = List[Real](length=len(t[].nodes), fill=0)
    if l.idx >= 0:
        adj[l.idx] = 1
    _sweep(t[], adj)
    var dp = List[Real]()
    for i in pi:
        dp.append(adj[i])
    var dx = List[Real]()
    for i in xi:
        dx.append(adj[i])
    var peak = len(t[].nodes)
    var lv = l.v
    _free_tape(t)
    return RevGrad(lv, dp^, dx^, peak)


def grad_checkpointed[S: RevSystem](sys: S, x0: List[Real], params: List[Real], steps: Int, every: Int) -> RevGrad:
    """`grad_full`'s gradient (bit for bit) keeping the state every `every`
    steps instead of the whole tape."""
    var stride = max(every, 1)
    # forward: checkpoints at segment starts
    var cps = List[List[Real]]()
    var cur = x0.copy()
    var peak = 0
    var done = 0
    while done < steps:
        cps.append(cur.copy())
        var n = min(stride, steps - done)
        var t = _new_tape()
        var p = _seed_all(t, params)
        var x = _seed_all(t, cur)
        for _ in range(n):
            sys.step(x, p)
        cur = _values(x)
        peak = max(peak, len(t[].nodes))
        _free_tape(t)
        done += n
    # backward over segments, last first
    var nseg = len(cps)
    var dstate = List[Real]()  # adjoint of the next segment's input state
    var dparam = List[Real](length=len(params), fill=0)
    var loss = Real(0)
    var s = nseg - 1
    while s >= 0:
        var n = stride if s < nseg - 1 else steps - stride * (nseg - 1)
        var t = _new_tape()
        var p = _seed_all(t, params)
        var x = _seed_all(t, cps[s])
        var pi = List[Int]()
        var xi = List[Int]()
        for v in p:
            pi.append(v.idx)
        for v in x:
            xi.append(v.idx)
        for _ in range(n):
            sys.step(x, p)
        var adj: List[Real]
        if s == nseg - 1:
            var l = sys.loss(x)
            loss = l.v
            adj = List[Real](length=len(t[].nodes), fill=0)
            if l.idx >= 0:
                adj[l.idx] = 1
        else:
            adj = List[Real](length=len(t[].nodes), fill=0)
            for i in range(len(x)):
                if x[i].idx >= 0:
                    adj[x[i].idx] += dstate[i]
        # the parameters' running adjoint continues from the later segments
        for i in range(len(pi)):
            adj[pi[i]] = dparam[i]
        peak = max(peak, len(t[].nodes))
        _sweep(t[], adj)
        dstate = List[Real]()
        for i in xi:
            dstate.append(adj[i])
        for i in range(len(pi)):
            dparam[i] = adj[pi[i]]
        _free_tape(t)
        s -= 1
    if nseg == 0:
        # zero steps: the loss of x0 itself
        var t = _new_tape()
        var x = _seed_all(t, x0)
        var l = sys.loss(x)
        var adj = List[Real](length=len(t[].nodes), fill=0)
        if l.idx >= 0:
            adj[l.idx] = 1
        _sweep(t[], adj)
        loss = l.v
        for v in x:
            dstate.append(adj[v.idx])
        _free_tape(t)
    return RevGrad(loss, dparam^, dstate^, peak)
