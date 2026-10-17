"""Gameplay rules (ROADMAP 17.70): attribute evaluator seam.

1000 actors x 4 attributes, K modifiers per attribute (K = 4, 16, 64, 256 --
the last is 1.02e6 modifiers in all); each
tick changes a fraction of the actors (one modifier removed and one added)
and then every attribute of every actor is read once. Cost per read for the
full recompute (scans K), the incremental sums (O(1) read; since the
override index an attribute without overrides no longer scans) and the
dirty cache.

Run with: `mojo run -I build benchmarks/bench_rules.mojo`.
"""

from std.benchmark import keep
from gameplay.rules import Attributes, EVAL_FULL, EVAL_INCREMENTAL, EVAL_DIRTY, OP_ADD, OP_MUL
from harness.bench import BenchTable, now


def run(mode: Int, k: Int, change_every: Int) -> Int:
    var actors = List[Attributes]()
    var handles = List[List[Int]]()
    for a in range(1000):
        var at = Attributes(4, mode)
        var hs = List[Int]()
        for j in range(4 * k):
            hs.append(at.add_modifier(j % 4, OP_ADD if j % 3 != 0 else OP_MUL, j + a))
        actors.append(at^)
        handles.append(hs^)
    var acc = 0
    var t0 = now()
    for tick in range(20):
        for a in range(0, 1000, change_every):
            var hs = handles[a].copy()
            var victim = hs[tick % len(hs)]
            _ = actors[a].remove_modifier(victim)
            hs[tick % len(hs)] = actors[a].add_modifier(tick % 4, OP_ADD, tick)
            handles[a] = hs^
        for a in range(1000):
            for j in range(4):
                acc += actors[a].value(j)
    var t1 = now()
    keep(acc)
    return t1 - t0


def main():
    var t = BenchTable("Attribute evaluators: 1000 actors x 4 attributes, 20 ticks (17.70)")
    var ks: List[Int] = [4, 16, 64, 256]
    var names: List[String] = ["full", "incremental", "dirty"]
    var modes: List[Int] = [EVAL_FULL, EVAL_INCREMENTAL, EVAL_DIRTY]
    for k in ks:
        for m in range(3):
            var ns = run(modes[m], k, 10)
            t.add(names[m] + " K=" + String(k) + ", 10 % changed per tick", 1000, "read", ns, 20 * 4000)
    t.print_report()
