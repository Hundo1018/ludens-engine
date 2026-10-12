"""Blackboard: keyed agent memory shared by decision makers (ROADMAP 17.15).

Keys are small integers the game defines (comptime constants); every key
holds a `Vec3` (a scalar lives in lane 0, a flag is 0 / 1), a set / unset
bit and a version that bumps on every write. Decision makers read it; the
host and perception write it. A blackboard is a plain value: copy one per
agent, or share one between a squad (several agents reading the same
`Blackboard` -- `test_ai_decision` covers that case).
"""

from geometry.vec import Real, Vec3

comptime CMP_SET = 0  # key is set
comptime CMP_UNSET = 1
comptime CMP_LT = 2  # lane 0 < value
comptime CMP_LE = 3
comptime CMP_GT = 4
comptime CMP_GE = 5
comptime CMP_EQ = 6
comptime CMP_NE = 7
comptime CMP_TRUE = 8  # set and lane 0 != 0
comptime CMP_FALSE = 9  # unset or lane 0 == 0


struct Blackboard(Copyable, Movable, Sized):
    var value: List[Vec3]
    var is_set: List[Bool]
    var version: List[Int]

    def __init__(out self, keys: Int):
        self.value = List[Vec3](length=keys, fill=Vec3(0))
        self.is_set = List[Bool](length=keys, fill=False)
        self.version = List[Int](length=keys, fill=0)

    def __len__(self) -> Int:
        return len(self.value)

    def set(mut self, k: Int, v: Real):
        self.value[k] = Vec3(v, 0, 0, 0)
        self.is_set[k] = True
        self.version[k] += 1

    def set_vec(mut self, k: Int, v: Vec3):
        self.value[k] = v
        self.is_set[k] = True
        self.version[k] += 1

    def set_flag(mut self, k: Int, b: Bool):
        self.set(k, Real(1) if b else Real(0))

    def clear(mut self, k: Int):
        if self.is_set[k]:
            self.is_set[k] = False
            self.version[k] += 1

    def has(self, k: Int) -> Bool:
        return self.is_set[k]

    def get(self, k: Int) -> Real:
        return self.value[k][0]

    def get_vec(self, k: Int) -> Vec3:
        return self.value[k]

    def flag(self, k: Int) -> Bool:
        return self.is_set[k] and self.value[k][0] != 0

    def test(self, k: Int, op: Int, v: Real) -> Bool:
        """Data-driven condition: `op` is one of the CMP_* constants."""
        if op == CMP_SET:
            return self.is_set[k]
        if op == CMP_UNSET:
            return not self.is_set[k]
        if op == CMP_TRUE:
            return self.flag(k)
        if op == CMP_FALSE:
            return not self.flag(k)
        if not self.is_set[k]:
            return False
        var x = self.value[k][0]
        if op == CMP_LT:
            return x < v
        if op == CMP_LE:
            return x <= v
        if op == CMP_GT:
            return x > v
        if op == CMP_GE:
            return x >= v
        if op == CMP_EQ:
            return x == v
        return x != v
