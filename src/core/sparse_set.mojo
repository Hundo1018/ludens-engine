# ===========================================================================
# SparseSet -- portable, pure-Mojo ECS entity/component set.
#
# This is the REAL engine core: the native oracle for the differential tests
# and the module the retarget pipeline will compile to wasm once `mojo` can
# emit LLVM IR (see STATUS.md). toolchain/standin/sparse_set.c mirrors its
# semantics/ABI so the wasm pipeline can be exercised before then.
#
# >>> COMPILE-GATED <<<
# Migrated from MAX 24.6 syntax to Mojo nightly per the mojo-nightly rules
# (fn->def, alias->comptime, out self, std. imports, Self.-qualified params,
# explicit trait conformance). It could NOT be compile-checked here because the
# Modular package channel is unreachable in this build environment, so `mojo`
# is not installed. Verify on a nightly toolchain with:
#     mojo run src/core/sparse_set.mojo
# ===========================================================================


struct SparseSet[fixed_size: Int, //, *keys: Int](Sized, Boolable, Copyable):
    comptime _fixed_size = fixed_size
    comptime _keys = VariadicList(keys)

    # key -> index into _dense, or -1. (A List keeps the migration free of any
    # InlineArray API uncertainty; swap to InlineArray[Int, Self._fixed_size]
    # for a zero-allocation sparse array once confirmed on the target nightly.)
    var _sparse: List[Int]
    var _dense: List[Int]   # packed live keys
    var _current: Int       # iteration cursor

    def __init__(out self):
        self._sparse = List[Int]()
        self._dense = List[Int]()
        self._current = -1
        for _ in range(Self._fixed_size):
            self._sparse.append(-1)
        for i in range(len(Self._keys)):
            self.add(Self._keys[i])

    def __copyinit__(out self, existing: Self):
        self._sparse = existing._sparse
        self._dense = existing._dense
        self._current = existing._current

    def __len__(self) -> Int:
        return len(self._dense)

    def __bool__(self) -> Bool:
        return len(self._dense) > 0

    def contains(self, key: Int) -> Bool:
        if key < 0 or key >= Self._fixed_size:
            return False
        var idx = self._sparse[key]
        return idx >= 0 and idx < len(self._dense) and self._dense[idx] == key

    def add(mut self, key: Int):
        """Add a key to the set (no-op if out of range or already present)."""
        if key < 0 or key >= Self._fixed_size:
            return
        if self.contains(key):
            return
        self._sparse[key] = len(self._dense)
        self._dense.append(key)

    def remove(mut self, key: Int):
        """Remove a key via canonical swap-remove."""
        if not self.contains(key):
            return
        var idx = self._sparse[key]
        var last = self._dense[len(self._dense) - 1]
        # Move `last` into the hole AND fix its sparse index. The original
        # sparseset.mojo omitted `self._sparse[last] = idx` -- a real bug that
        # this migration corrects (see tests/differential).
        self._dense[idx] = last
        self._sparse[last] = idx
        _ = self._dense.pop()
        self._sparse[key] = -1

    # --- iteration (native only; the wasm core iterates via ss_dense_at) ------
    def __iter__(self) -> Self:
        var it = self          # iterate over a copy so the cursor is private
        it._current = -1
        return it

    def __has_next__(self) -> Bool:
        return self._current < len(self._dense) - 1

    def __next__(mut self) -> Int:
        self._current += 1
        return self._dense[self._current]


def main():
    var my_set = SparseSet[fixed_size=4, 2, 1]()
    print("len:", len(my_set))
    for element in my_set:
        print(element)
