"""Derived parent→children ordering for transform propagation.

`Hierarchy` is an out-of-world helper rebuilt each pass from the world's current
`Transform` and `Parent` components — the same "rebuild the index from a query"
discipline `DamageSystem` uses, required because the storage backends keep no
stable interior pointers and expose no relationships. It produces a *parents-
first* topological order so a single linear walk computes every world matrix.

The world must carry both `Transform` (slot 0) and `Parent` (slot 1).
"""

from .world import World
from .storage import StorageBackend
from .entity import Entity
from .transform import Transform, Parent


struct Hierarchy(Movable, ImplicitlyDeletable):
    var order: List[Entity]  # entities, every parent before its children
    var parent_of: List[Int]  # id -> parent id (-1 = root); sized max_id + 1

    def __init__(out self):
        self.order = List[Entity]()
        self.parent_of = List[Int]()

    @staticmethod
    def build[B: StorageBackend](w: World[B]) -> Hierarchy:
        var h = Hierarchy()
        var tes = w.query1[Transform]()
        var n = len(tes)
        if n == 0:
            return h^
        var max_id = 0
        for i in range(n):
            if tes[i].id > max_id:
                max_id = tes[i].id

        var present = List[Bool]()
        var parent_of = List[Int]()
        var emitted = List[Bool]()
        for _ in range(max_id + 1):
            present.append(False)
            parent_of.append(-1)
            emitted.append(False)
        for i in range(n):
            present[tes[i].id] = True

        var pes = w.query1[Parent]()
        for i in range(len(pes)):
            parent_of[pes[i].id] = w.get[Parent](pes[i]).entity

        # Topological emit: a node is ready once its parent is absent or emitted.
        var order = List[Entity]()
        var remaining = n
        while remaining > 0:
            var progressed = False
            for k in range(n):
                var e = tes[k]
                if emitted[e.id]:
                    continue
                var par = parent_of[e.id]
                var ready = par < 0 or par > max_id
                if not ready and not present[par]:
                    ready = True
                if not ready and emitted[par]:
                    ready = True
                if ready:
                    order.append(e)
                    emitted[e.id] = True
                    remaining -= 1
                    progressed = True
            if not progressed:
                # cycle guard: emit the rest in arbitrary order
                for k in range(n):
                    if not emitted[tes[k].id]:
                        order.append(tes[k])
                        emitted[tes[k].id] = True
                remaining = 0

        h.order = order^
        h.parent_of = parent_of^
        return h^
