"""Inventory slots and loot tables (ROADMAP 17.72).

`Inventory`: N slots of (item, count) with a per-item stack limit. `add`
tops up existing stacks of the item first, then fills empty slots, and
returns what did not fit; `remove` takes from the last stacks first and
returns how many it took. `count(item)` sums the stacks.

`LootTable`: weighted entries (item, weight, min, max count). `roll` draws
with a seeded `Pcg32` - the same seed gives the same drops on every
machine - and returns (item, count) pairs. Entries of weight 0 never drop.
"""

from scheduler.rng import Pcg32


struct Inventory(Copyable, Movable):
    var item: List[Int]  # -1 = empty
    var count: List[Int]
    var stack_limit: List[Int]  # per item id

    def __init__(out self, slots: Int, stack_limit: List[Int]):
        self.item = List[Int](length=slots, fill=-1)
        self.count = List[Int](length=slots, fill=0)
        self.stack_limit = stack_limit.copy()

    def add(mut self, item: Int, n: Int) raises -> Int:
        if item < 0 or item >= len(self.stack_limit) or n < 0:
            raise Error("Inventory.add: unknown item or negative count")
        var left = n
        var cap = self.stack_limit[item]
        for s in range(len(self.item)):
            if left == 0:
                break
            if self.item[s] == item and self.count[s] < cap:
                var put = min(left, cap - self.count[s])
                self.count[s] += put
                left -= put
        for s in range(len(self.item)):
            if left == 0:
                break
            if self.item[s] == -1:
                var put = min(left, cap)
                self.item[s] = item
                self.count[s] = put
                left -= put
        return left

    def remove(mut self, item: Int, n: Int) -> Int:
        var left = n
        var s = len(self.item) - 1
        while s >= 0 and left > 0:
            if self.item[s] == item:
                var take = min(left, self.count[s])
                self.count[s] -= take
                left -= take
                if self.count[s] == 0:
                    self.item[s] = -1
            s -= 1
        return n - left

    def count_of(self, item: Int) -> Int:
        var c = 0
        for s in range(len(self.item)):
            if self.item[s] == item:
                c += self.count[s]
        return c


@fieldwise_init
struct LootEntry(Copyable, ImplicitlyCopyable, Movable):
    var item: Int
    var weight: Int
    var min_count: Int
    var max_count: Int


struct LootTable(Copyable, Movable):
    var entries: List[LootEntry]
    var total: Int

    def __init__(out self):
        self.entries = List[LootEntry]()
        self.total = 0

    def add(mut self, item: Int, weight: Int, min_count: Int = 1, max_count: Int = 1) raises:
        if weight < 0 or min_count < 0 or max_count < min_count:
            raise Error("LootTable.add: weight >= 0 and 0 <= min <= max")
        self.entries.append(LootEntry(item, weight, min_count, max_count))
        self.total += weight

    def roll(self, seed: UInt64, draws: Int) -> List[Tuple[Int, Int]]:
        var out = List[Tuple[Int, Int]]()
        if self.total == 0:
            return out^
        var rng = Pcg32.seeded(seed)
        for _ in range(draws):
            var r = Int(rng.next_u32() % UInt32(self.total))
            for e in self.entries:
                if r < e.weight:
                    var span = e.max_count - e.min_count + 1
                    var c = e.min_count + Int(rng.next_u32() % UInt32(span))
                    out.append((e.item, c))
                    break
                r -= e.weight
        return out^
