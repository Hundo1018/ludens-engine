"""Host-defined components (ROADMAP 17.78).

Compile-time components carry a `comptime ID` and live in a
`StorageBackend`; a host script cannot add one at run time. `HostComponents`
holds components registered at run time by (name, size in bytes) as dense
byte rows per component, keyed by entity, beside any `World` and without
touching the backends' generic contract:

  * `register(name, size)` -> component id (names unique, size > 0);
  * `set` / `get` / `has` / `remove` by `Entity` (generation checked: a stale
    handle reads as absent), `set_f64` / `get_f64` at a byte offset for
    scripting hosts, `matching(cid)` and `matching_all(cids)` queries,
    `despawn(e)` to drop an entity from every component;
  * removal swaps the last row into the hole, so storage stays dense;
  * `to_bytes` / `from_bytes` round-trip the whole store.
"""

from std.collections import Dict
from .entity import Entity


def _f64_bits(v: Float64) -> UInt64:
    var x = v
    return Pointer(to=x).unsafe_bitcast[UInt64]()[]


def _bits_f64(u: UInt64) -> Float64:
    var x = u
    return Pointer(to=x).unsafe_bitcast[Float64]()[]


struct HostComponents(Movable):
    var names: List[String]
    var sizes: List[Int]
    var row_of: List[Dict[Int, Int]]  # per component: entity id -> row
    var row_ent: List[List[Entity]]  # per component: row -> entity
    var data: List[List[UInt8]]  # per component: rows x size bytes

    def __init__(out self):
        self.names = List[String]()
        self.sizes = List[Int]()
        self.row_of = List[Dict[Int, Int]]()
        self.row_ent = List[List[Entity]]()
        self.data = List[List[UInt8]]()

    def register(mut self, name: String, size: Int) raises -> Int:
        if size <= 0:
            raise Error("HostComponents.register: size must be > 0")
        for n in self.names:
            if n == name:
                raise Error("HostComponents.register: '" + name + "' already registered")
        self.names.append(name)
        self.sizes.append(size)
        self.row_of.append(Dict[Int, Int]())
        self.row_ent.append(List[Entity]())
        self.data.append(List[UInt8]())
        return len(self.names) - 1

    def id_of(self, name: String) -> Int:
        for k in range(len(self.names)):
            if self.names[k] == name:
                return k
        return -1

    def _check(self, cid: Int) raises:
        if cid < 0 or cid >= len(self.names):
            raise Error("HostComponents: unknown component id")

    def _row(self, e: Entity, cid: Int) -> Int:
        var r = self.row_of[cid].get(e.id, -1)
        if r < 0 or self.row_ent[cid][r].gen != e.gen:
            return -1
        return r

    def has(self, e: Entity, cid: Int) -> Bool:
        return cid >= 0 and cid < len(self.names) and self._row(e, cid) >= 0

    def set(mut self, e: Entity, cid: Int, bytes: List[UInt8]) raises:
        self._check(cid)
        var sz = self.sizes[cid]
        if len(bytes) != sz:
            raise Error("HostComponents.set: expected " + String(sz) + " bytes")
        var r = self._row(e, cid)
        if r < 0:
            var old = self.row_of[cid].get(e.id, -1)
            if old >= 0:  # a stale generation occupies the id: replace it
                self._remove_row(cid, old)
            r = len(self.row_ent[cid])
            self.row_of[cid][e.id] = r
            self.row_ent[cid].append(e)
            for b in bytes:
                self.data[cid].append(b)
            return
        for k in range(sz):
            self.data[cid][r * sz + k] = bytes[k]

    def get(self, e: Entity, cid: Int) raises -> List[UInt8]:
        self._check(cid)
        var r = self._row(e, cid)
        if r < 0:
            raise Error("HostComponents.get: entity has no '" + self.names[cid] + "'")
        var sz = self.sizes[cid]
        var out = List[UInt8](capacity=sz)
        for k in range(sz):
            out.append(self.data[cid][r * sz + k])
        return out^

    def set_f64(mut self, e: Entity, cid: Int, offset: Int, v: Float64) raises:
        """Write a little-endian f64 at `offset`; adds the component (zeroed)
        if the entity lacks it."""
        self._check(cid)
        if offset < 0 or offset + 8 > self.sizes[cid]:
            raise Error("HostComponents.set_f64: offset out of the component")
        if self._row(e, cid) < 0:
            self.set(e, cid, List[UInt8](length=self.sizes[cid], fill=0))
        var r = self._row(e, cid)
        var u = _f64_bits(v)
        var base = r * self.sizes[cid] + offset
        for k in range(8):
            self.data[cid][base + k] = UInt8((u >> UInt64(8 * k)) & 0xFF)

    def get_f64(self, e: Entity, cid: Int, offset: Int) raises -> Float64:
        self._check(cid)
        if offset < 0 or offset + 8 > self.sizes[cid]:
            raise Error("HostComponents.get_f64: offset out of the component")
        var r = self._row(e, cid)
        if r < 0:
            raise Error("HostComponents.get_f64: entity has no '" + self.names[cid] + "'")
        var u = UInt64(0)
        var base = r * self.sizes[cid] + offset
        for k in range(8):
            u |= UInt64(self.data[cid][base + k]) << UInt64(8 * k)
        return _bits_f64(u)

    def _remove_row(mut self, cid: Int, r: Int):
        var sz = self.sizes[cid]
        var last = len(self.row_ent[cid]) - 1
        var gone = self.row_ent[cid][r]
        if r != last:
            var moved = self.row_ent[cid][last]
            self.row_ent[cid][r] = moved
            self.row_of[cid][moved.id] = r
            for k in range(sz):
                self.data[cid][r * sz + k] = self.data[cid][last * sz + k]
        _ = self.row_ent[cid].pop()
        for _ in range(sz):
            _ = self.data[cid].pop()
        try:  # one row per id, so the removed entity's id is never the moved one's
            _ = self.row_of[cid].pop(gone.id)
        except:
            pass

    def remove(mut self, e: Entity, cid: Int):
        if cid < 0 or cid >= len(self.names):
            return
        var r = self._row(e, cid)
        if r >= 0:
            self._remove_row(cid, r)

    def despawn(mut self, e: Entity):
        for cid in range(len(self.names)):
            self.remove(e, cid)

    def matching(self, cid: Int) -> List[Entity]:
        if cid < 0 or cid >= len(self.names):
            return List[Entity]()
        return self.row_ent[cid].copy()

    def matching_all(self, cids: List[Int]) -> List[Entity]:
        """Entities holding every component in `cids` (walks the smallest)."""
        var out = List[Entity]()
        if len(cids) == 0:
            return out^
        var best = cids[0]
        for c in cids:
            if c < 0 or c >= len(self.names):
                return out^
            if len(self.row_ent[c]) < len(self.row_ent[best]):
                best = c
        for e in self.row_ent[best]:
            var ok = True
            for c in cids:
                if self._row(e, c) < 0:
                    ok = False
                    break
            if ok:
                out.append(e)
        return out^

    def to_bytes(self) -> List[UInt8]:
        var out = List[UInt8]()
        _put(out, len(self.names))
        for c in range(len(self.names)):
            var nb = self.names[c].as_bytes()
            _put(out, len(nb))
            for b in nb:
                out.append(b)
            _put(out, self.sizes[c])
            _put(out, len(self.row_ent[c]))
            for e in self.row_ent[c]:
                _put(out, e.id)
                _put(out, e.gen)
            for b in self.data[c]:
                out.append(b)
        return out^

    @staticmethod
    def from_bytes(d: List[UInt8]) raises -> HostComponents:
        var hc = HostComponents()
        var at = 0
        var nc = _get(d, at)
        at += 8
        for _ in range(nc):
            var ln = _get(d, at)
            at += 8
            if ln < 0 or at + ln > len(d):
                raise Error("HostComponents.from_bytes: truncated")
            var chars = List[UInt8]()
            for k in range(ln):
                chars.append(d[at + k])
            var name = String(unsafe_from_utf8=chars)
            at += ln
            var sz = _get(d, at)
            at += 8
            var cid = hc.register(name, sz)
            var rows = _get(d, at)
            at += 8
            if rows < 0:
                raise Error("HostComponents.from_bytes: corrupt row count")
            for r in range(rows):
                var e = Entity(_get(d, at), _get(d, at + 8))
                at += 16
                hc.row_of[cid][e.id] = r
                hc.row_ent[cid].append(e)
            if at + rows * sz > len(d):
                raise Error("HostComponents.from_bytes: truncated")
            for k in range(rows * sz):
                hc.data[cid].append(d[at + k])
            at += rows * sz
        return hc^


def _put(mut out: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _get(d: List[UInt8], at: Int) raises -> Int:
    if at + 8 > len(d):
        raise Error("HostComponents.from_bytes: truncated")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(d[at + k]) << UInt64(8 * k)
    return Int(u)
