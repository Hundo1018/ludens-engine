# Spike 3+4: the Dispatch axis as a swappable policy.
#   - `DispatchPolicy` trait with a `comptime PARALLEL: Bool` marker and a static
#     `run[body](n)` that drives a closure over [0, n).
#   - `Serial` = plain loop; `Parallel` = `parallelize` (worker threads).
# The closure writes only its own disjoint arena slot `arena[i]` (no shared
# mutation), so a following serial reduce is identical for both policies.

from max.algorithm import parallelize
from std.memory import alloc, Layout


trait DispatchPolicy:
    # Pure static-dispatch policy — never instantiated, so no value supertraits.
    comptime PARALLEL: Bool

    @staticmethod
    def run[F: def (Int) -> None](body: F, n: Int): ...


struct Serial(DispatchPolicy):
    comptime PARALLEL = False

    @staticmethod
    def run[F: def (Int) -> None](body: F, n: Int):
        for i in range(n):
            body(i)


struct Parallel(DispatchPolicy):
    comptime PARALLEL = True

    @staticmethod
    def run[F: def (Int) -> None](body: F, n: Int):
        parallelize(body, n)


def square_sum[D: DispatchPolicy](n: Int) -> Int:
    var arena = alloc[Int](Layout[Int](count=n)).unsafe_leak()

    def worker(i: Int) {imm arena}:
        arena[unsafe_offset=i] = i * i  # disjoint slot: worker i touches only arena[i]

    D.run(worker, n)

    var s = 0
    for i in range(n):
        s += arena[unsafe_offset=i]
    arena.unsafe_free()
    return s


def main() raises:
    # sum of i*i for i in 0..9 == 285, identical for both policies
    var ser = square_sum[Serial](10)
    var par = square_sum[Parallel](10)
    if ser != 285 or par != 285:
        raise Error("FAIL: serial=" + String(ser) + " parallel=" + String(par))
    print("spike_dispatch_policy: PASS serial =", ser, "parallel =", par)
