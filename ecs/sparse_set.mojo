"""A sparse set: O(1) add / contains / remove with dense, cache-friendly storage.

Two parallel dense arrays hold keys (`_dense`) and values (`_data`); `_sparse`
maps a key to its dense index (or -1). This is the per-component store for the
sparse-set ECS backend and the entity->record index for the archetype backend.

`_sparse` is a heap `List[Int]` that grows geometrically on demand, so there is
no fixed capacity and no per-`cap` codegen blow-up — entity ids are unbounded.
Values must be `ImplicitlyCopyable` so they can be read back by value.
"""

from std.collections import List


@fieldwise_init
struct _SparseSetIter[
    mut: Bool,
    //,
    T: ImplicitlyCopyable & ImplicitlyDeletable,
    origin: Origin[mut=mut],
](Iterator):
    comptime Element = Self.T  # Required by the Iterator trait

    var index: Int
    var src: Pointer[SparseSet[Self.T], Self.origin]

    def __has_next__(self) -> Bool:
        return self.index < len(self.src[])

    def __next__(mut self) -> Self.T:
        var val = self.src[]._data[self.index]
        self.index += 1
        return val


struct SparseSet[T: ImplicitlyCopyable & ImplicitlyDeletable](
    Boolable, Copyable, Movable, Defaultable, Iterable, Sized
):
    var _sparse: List[Int]  # key -> dense index (or -1); grows on demand
    # dense array of keys
    var _dense: List[Int]
    # dense array of values, parallel to _dense
    var _data: List[Self.T]

    comptime IteratorType[
        iterable_mut: Bool, //, iterable_origin: Origin[mut=iterable_mut]
    ]: Iterator = _SparseSetIter[Self.T, iterable_origin]

    def __iter__(ref self) -> Self.IteratorType[origin_of(self)]:
        return {0, Pointer(to=self)}

    def __init__(out self):
        self._sparse = List[Int]()
        self._dense = List[Int]()
        self._data = List[Self.T]()

    def _ensure(mut self, key: Int):
        """Grow `_sparse` (geometrically) so `key` is a valid index, -1-filled."""
        if key < len(self._sparse):
            return
        var new_cap = len(self._sparse)
        if new_cap < 8:
            new_cap = 8
        while new_cap <= key:
            new_cap += new_cap
        while len(self._sparse) < new_cap:
            self._sparse.append(-1)

    @always_inline
    def __len__(self) -> Int:
        return len(self._dense)

    def __bool__(self) -> Bool:
        return len(self) > 0

    @always_inline
    def contains(read self, key: Int) -> Bool:
        if key < 0 or key >= len(self._sparse):
            return False
        var index = self._sparse[key]
        return (
            index >= 0
            and index < len(self._dense)
            and self._dense[index] == key
        )

    def add(mut self, key: Int, value: Self.T):
        """Insert a key/value; no-op if the key is already present (use `set` to overwrite)."""
        if self.contains(key):
            return
        self._ensure(key)
        self._sparse[key] = len(self._dense)
        self._dense.append(key)
        self._data.append(value)

    def set(mut self, key: Int, value: Self.T):
        """Insert or overwrite the value for `key`."""
        if self.contains(key):
            self._data[self._sparse[key]] = value
        else:
            self.add(key, value)

    @always_inline
    def get(self, key: Int) -> Self.T:
        """Value for `key`; caller must ensure `contains(key)`."""
        return self._data[self._sparse[key]]

    def remove(mut self, key: Int):
        if not self.contains(key):
            return
        var index = self._sparse[key]
        var last_idx = len(self._dense) - 1
        var last_key = self._dense[last_idx]
        # Move the last element into the hole to keep the arrays dense.
        self._dense[index] = last_key
        self._data[index] = self._data[last_idx]
        self._sparse[last_key] = index
        self._sparse[key] = -1
        _ = self._dense.pop()
        _ = self._data.pop()

    # --- dense iteration helpers (used by ECS queries) ---
    @always_inline
    def dense_len(self) -> Int:
        return len(self._dense)

    @always_inline
    def key_at(self, i: Int) -> Int:
        return self._dense[i]

    @always_inline
    def value_at(self, i: Int) -> Self.T:
        return self._data[i]
