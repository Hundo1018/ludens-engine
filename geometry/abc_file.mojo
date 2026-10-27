"""Alembic (Ogawa) files: animated meshes, points and curves (ROADMAP 17.63).

`AbcArchive` collects per-frame samples of three kinds of objects under the
archive's root and `bytes()` writes them as an Alembic archive in the Ogawa
container, the layout of Alembic 1.8's AbcCoreOgawa:

  - Ogawa: a 16-byte header ("Ogawa", frozen byte 0xff, version 1, root
    group offset), groups (u64 child count, then u64 child offsets, bit 63
    marking data) and data blocks (u64 size, bytes); offset 0 is the empty
    group / data. Children are written before their group.
  - The archive group: format version 0, library version 10803, the root
    object, archive metadata, the time samplings (the identity one and
    one uniform sampling at 1 / fps from `start`) and an empty indexed
    metadata table (all metadata is written inline).
  - An object group: its property compound, its child objects, then the
    child headers (name, metadata) and two 16-byte hashes (zeros here).
  - A compound property group: one group per property, then the headers
    (a u32 of bit fields -- type, size hint, POD, time sampling flag,
    homogeneous, constant, extent, metadata index 0xff -- then the sample
    count, time sampling index, name and metadata, sized per the hint).
  - A property group: per sample, the data (a 16-byte key, then the
    values; the key is two FNV-1a 64 hashes, readers do not check it)
    and, for arrays, an empty dimensions block (rank 1). A sample equal
    to the previous one reuses its data block; a property whose samples
    are all equal is written once and flagged constant.

Objects: `add_mesh` (AbcGeom_PolyMesh_v1: P, .faceIndices, .faceCounts,
.selfBnds; topology may change per frame), `add_points`
(AbcGeom_Points_v1: P, .pointIds, .selfBnds) and `add_curves`
(AbcGeom_Curve_v2, linear non-periodic: P, nVertices, curveBasisAndType,
.selfBnds). Faces are given counter-clockwise and written clockwise,
Alembic's convention, so importers that flip back (Blender) see the input
order.

`abc_read(bytes)` reads back what `bytes()` writes: the objects with their
per-frame positions, faces (counter-clockwise, as given), counts and ids. It
reads this writer's layout only; a foreign Alembic file is not in scope.

Checked against a real reader: `pixi run abc-check` imports the files
`test_abc_file` writes with Blender's Alembic importer (`bpy`,
`scripts/abc_check.py`) and compares every frame's positions and
topology. The encoder produces bytes; files are the host's business.
"""

from .vec import Real

comptime ABC_MESH = 0
comptime ABC_POINTS = 1
comptime ABC_CURVES = 2

comptime _POD_U8 = 1
comptime _POD_I32 = 6
comptime _POD_U64 = 7
comptime _POD_F32 = 10
comptime _POD_F64 = 11

comptime _DATA_BIT = UInt64(1) << 63


def _put_u32(mut b: List[UInt8], v: Int):
    for k in range(4):
        b.append(UInt8((v >> (8 * k)) & 0xFF))


def _put_u64(mut b: List[UInt8], v: UInt64):
    for k in range(8):
        b.append(UInt8((v >> UInt64(8 * k)) & 0xFF))


def _put_f32(mut b: List[UInt8], v: Real):
    var x = Float32(v)
    _put_u32(b, Int(Pointer(to=x).unsafe_bitcast[UInt32]()[]))


def _put_f64(mut b: List[UInt8], v: Float64):
    var x = v
    _put_u64(b, Pointer(to=x).unsafe_bitcast[UInt64]()[])


def _put_str(mut b: List[UInt8], s: String):
    for c in s.as_bytes():
        b.append(c)


def _fnv(b: List[UInt8], basis: UInt64) -> UInt64:
    var h = basis
    for c in b:
        h = (h ^ UInt64(c)) * UInt64(0x100000001B3)
    return h


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


struct _Prop(Copyable, Movable):
    """One property of an object's .geom compound: its header fields and
    the sample payloads (values only, no key)."""

    var name: String
    var meta: String
    var is_array: Bool
    var pod: Int
    var extent: Int
    var samples: List[List[UInt8]]

    def __init__(out self, name: String, meta: String, is_array: Bool, pod: Int, extent: Int):
        self.name = name
        self.meta = meta
        self.is_array = is_array
        self.pod = pod
        self.extent = extent
        self.samples = List[List[UInt8]]()


struct _Obj(Copyable, Movable):
    var name: String
    var kind: Int
    var props: List[_Prop]

    def __init__(out self, name: String, kind: Int):
        self.name = name
        self.kind = kind
        self.props = List[_Prop]()
        if kind == ABC_MESH:
            self.props.append(_Prop("P", "geoScope=vtx;interpretation=point", True, _POD_F32, 3))
            self.props.append(_Prop(".faceIndices", "", True, _POD_I32, 1))
            self.props.append(_Prop(".faceCounts", "", True, _POD_I32, 1))
        elif kind == ABC_POINTS:
            self.props.append(_Prop("P", "geoScope=var;interpretation=point", True, _POD_F32, 3))
            self.props.append(_Prop(".pointIds", "geoScope=var", True, _POD_U64, 1))
        else:
            self.props.append(_Prop("P", "geoScope=vtx;interpretation=point", True, _POD_F32, 3))
            self.props.append(_Prop("nVertices", "", True, _POD_I32, 1))
            self.props.append(_Prop("curveBasisAndType", "", False, _POD_U8, 4))
        self.props.append(_Prop(".selfBnds", "interpretation=box", False, _POD_F64, 6))

    def schema(self) -> String:
        if self.kind == ABC_MESH:
            return "AbcGeom_PolyMesh_v1"
        if self.kind == ABC_POINTS:
            return "AbcGeom_Points_v1"
        return "AbcGeom_Curve_v2"


struct _Ogawa(Movable):
    var b: List[UInt8]

    def __init__(out self):
        self.b = List[UInt8]()
        _put_str(self.b, "Ogawa")
        self.b.append(0xFF)  # frozen
        self.b.append(0)
        self.b.append(1)  # version 1 (big-endian u16)
        _put_u64(self.b, 0)  # root offset, patched by `finish`

    def data(mut self, payload: List[UInt8]) -> UInt64:
        if len(payload) == 0:
            return _DATA_BIT
        var at = len(self.b)
        _put_u64(self.b, UInt64(len(payload)))
        for c in payload:
            self.b.append(c)
        return UInt64(at) | _DATA_BIT

    def group(mut self, kids: List[UInt64]) -> UInt64:
        if len(kids) == 0:
            return 0
        var at = len(self.b)
        _put_u64(self.b, UInt64(len(kids)))
        for k in kids:
            _put_u64(self.b, k)
        return UInt64(at)

    def finish(mut self, root: UInt64) -> List[UInt8]:
        for k in range(8):
            self.b[8 + k] = UInt8((root >> UInt64(8 * k)) & 0xFF)
        return self.b.copy()


def _keyed(p: List[UInt8]) -> List[UInt8]:
    var out = List[UInt8](capacity=len(p) + 16)
    _put_u64(out, _fnv(p, 0xCBF29CE484222325))
    _put_u64(out, _fnv(p, 0x84222325CBF29CE4))
    for c in p:
        out.append(c)
    return out^


def _write_prop(mut og: _Ogawa, p: _Prop, mut headers: List[UInt8]) -> UInt64:
    """Writes the property's group (its samples), appends its header to
    `headers` and returns the group's offset."""
    var n = len(p.samples)
    var constant = True
    for i in range(1, n):
        if not _same(p.samples[i], p.samples[i - 1]):
            constant = False
    var stored = 1 if constant else n
    var kids = List[UInt64]()
    var prev = UInt64(0)
    for i in range(min(stored, n)):
        var d: UInt64
        if i > 0 and _same(p.samples[i], p.samples[i - 1]):
            d = prev
        else:
            d = og.data(_keyed(p.samples[i]))
        prev = d
        kids.append(d)
        if p.is_array:
            kids.append(_DATA_BIT)  # rank-1 dimensions: implied by the size
    var tsidx = 1 if n > 0 else 0
    var big = max(n, max(p.name.byte_length(), p.meta.byte_length()))
    var hint = 0 if big < 256 else (1 if big < 65536 else 2)
    var info = (2 if p.is_array else 1) | (hint << 2) | (p.pod << 4)
    if tsidx != 0:
        info |= 0x100
    if not p.is_array:
        info |= 0x400  # homogeneous; left clear on arrays (readers then read every sample's size)
    if constant:
        info |= 0x800
    info |= p.extent << 12
    var meta_inline = p.meta.byte_length() > 0
    info |= (0xFF if meta_inline else 0) << 20
    _put_u32(headers, info)
    _put_sized(headers, n, hint)
    if tsidx != 0:
        _put_sized(headers, tsidx, hint)
    _put_sized(headers, p.name.byte_length(), hint)
    _put_str(headers, p.name)
    if meta_inline:
        _put_sized(headers, p.meta.byte_length(), hint)
        _put_str(headers, p.meta)
    return og.group(kids)


def _put_sized(mut b: List[UInt8], v: Int, hint: Int):
    var n = 1 if hint == 0 else (2 if hint == 1 else 4)
    for k in range(n):
        b.append(UInt8((v >> (8 * k)) & 0xFF))


def _compound_header(mut headers: List[UInt8], name: String, meta: String):
    var big = max(name.byte_length(), meta.byte_length())
    var hint = 0 if big < 256 else (1 if big < 65536 else 2)
    var info = hint << 2
    if meta.byte_length() > 0:
        info |= 0xFF << 20
    _put_u32(headers, info)
    _put_sized(headers, name.byte_length(), hint)
    _put_str(headers, name)
    if meta.byte_length() > 0:
        _put_sized(headers, meta.byte_length(), hint)
        _put_str(headers, meta)


def _bounds(pos: List[Real]) -> List[UInt8]:
    """Box3d as Alembic stores it: min xyz, max xyz (f64); an empty set is
    (DBL_MAX, -DBL_MAX) like Alembic's empty box."""
    var lo = List[Float64](length=3, fill=1.7976931348623157e308)
    var hi = List[Float64](length=3, fill=-1.7976931348623157e308)
    for i in range(len(pos) // 3):
        for c in range(3):
            var v = Float64(Float32(pos[3 * i + c]))
            lo[c] = min(lo[c], v)
            hi[c] = max(hi[c], v)
    var b = List[UInt8]()
    for c in range(3):
        _put_f64(b, lo[c])
    for c in range(3):
        _put_f64(b, hi[c])
    return b^


def _f32s(pos: List[Real]) -> List[UInt8]:
    var b = List[UInt8](capacity=4 * len(pos))
    for v in pos:
        _put_f32(b, v)
    return b^


def _i32s(v: List[Int]) -> List[UInt8]:
    var b = List[UInt8](capacity=4 * len(v))
    for x in v:
        _put_u32(b, x)
    return b^


struct AbcArchive(Movable):
    """Objects under the root, each with per-frame samples taken at
    `start + i / fps` seconds (frame i)."""

    var fps: Float64
    var start: Float64
    var objs: List[_Obj]

    def __init__(out self, fps: Float64 = 24, start: Float64 = 0) raises:
        if not (fps > 0):
            raise Error("AbcArchive: fps must be > 0")
        self.fps = fps
        self.start = start
        self.objs = List[_Obj]()

    def _add(mut self, name: String, kind: Int) raises -> Int:
        if name.byte_length() == 0 or "/" in name:
            raise Error("AbcArchive: object names are non-empty and contain no '/'")
        for ref o in self.objs:
            if o.name == name:
                raise Error("AbcArchive: duplicate object name " + name)
        self.objs.append(_Obj(name, kind))
        return len(self.objs) - 1

    def add_mesh(mut self, name: String) raises -> Int:
        return self._add(name, ABC_MESH)

    def add_points(mut self, name: String) raises -> Int:
        return self._add(name, ABC_POINTS)

    def add_curves(mut self, name: String) raises -> Int:
        return self._add(name, ABC_CURVES)

    def _check(self, obj: Int, kind: Int, pos: List[Real]) raises:
        if obj < 0 or obj >= len(self.objs) or self.objs[obj].kind != kind:
            raise Error("AbcArchive: no object of that kind at this index")
        if len(pos) % 3 != 0:
            raise Error("AbcArchive: positions are x, y, z triples")

    def mesh_frame(mut self, obj: Int, pos: List[Real], face_counts: List[Int], face_indices: List[Int]) raises:
        """One frame of a polygon mesh: positions (x, y, z per vertex), the
        vertex count of each face and the faces' vertex indices,
        counter-clockwise. The topology may differ from the last frame's."""
        self._check(obj, ABC_MESH, pos)
        var nv = len(pos) // 3
        var total = 0
        for c in face_counts:
            if c < 1:
                raise Error("AbcArchive.mesh_frame: face with no vertices")
            total += c
        if total != len(face_indices):
            raise Error("AbcArchive.mesh_frame: face counts do not add up to the index count")
        for i in face_indices:
            if i < 0 or i >= nv:
                raise Error("AbcArchive.mesh_frame: vertex index out of range")
        var cw = List[Int](capacity=len(face_indices))
        var at = 0
        for c in face_counts:
            for k in range(c):
                cw.append(face_indices[at + c - 1 - k])
            at += c
        ref o = self.objs[obj]
        o.props[0].samples.append(_f32s(pos))
        o.props[1].samples.append(_i32s(cw))
        o.props[2].samples.append(_i32s(face_counts))
        o.props[3].samples.append(_bounds(pos))

    def points_frame(mut self, obj: Int, pos: List[Real], ids: List[Int]) raises:
        """One frame of particles: positions and one id per particle (ids
        let a reader follow particles while the count changes)."""
        self._check(obj, ABC_POINTS, pos)
        if len(ids) != len(pos) // 3:
            raise Error("AbcArchive.points_frame: one id per point")
        var b = List[UInt8](capacity=8 * len(ids))
        for i in ids:
            if i < 0:
                raise Error("AbcArchive.points_frame: ids are >= 0")
            _put_u64(b, UInt64(i))
        ref o = self.objs[obj]
        o.props[0].samples.append(_f32s(pos))
        o.props[1].samples.append(b^)
        o.props[2].samples.append(_bounds(pos))

    def curves_frame(mut self, obj: Int, pos: List[Real], counts: List[Int]) raises:
        """One frame of linear curves (strands): positions and the vertex
        count of each curve, curves stored one after another."""
        self._check(obj, ABC_CURVES, pos)
        var total = 0
        for c in counts:
            if c < 2:
                raise Error("AbcArchive.curves_frame: a curve has at least 2 vertices")
            total += c
        if total != len(pos) // 3:
            raise Error("AbcArchive.curves_frame: curve counts do not add up to the vertex count")
        ref o = self.objs[obj]
        o.props[0].samples.append(_f32s(pos))
        o.props[1].samples.append(_i32s(counts))
        var bt: List[UInt8] = [1, 0, 0, 3]  # linear, non-periodic, no basis, step 3
        o.props[2].samples.append(bt^)
        o.props[3].samples.append(_bounds(pos))

    def frames(self, obj: Int) -> Int:
        return len(self.objs[obj].props[0].samples)

    def bytes(self) -> List[UInt8]:
        var og = _Ogawa()
        var root_kids = List[UInt64]()
        root_kids.append(0)  # root object: no properties
        var child_headers = List[UInt8]()
        var max_frames = 0
        for ref o in self.objs:
            # .geom compound
            var geom_kids = List[UInt64]()
            var geom_headers = List[UInt8]()
            for ref p in o.props:
                geom_kids.append(_write_prop(og, p, geom_headers))
                max_frames = max(max_frames, len(p.samples))
            geom_kids.append(og.data(geom_headers))
            var top_headers = List[UInt8]()
            var schema = o.schema()
            _compound_header(top_headers, ".geom", "schema=" + schema + ";schemaBaseType=AbcGeom_GeomBase_v1")
            var top: List[UInt64] = [og.group(geom_kids), og.data(top_headers)]
            var hashes = List[UInt8](length=32, fill=0)
            var obj: List[UInt64] = [og.group(top), og.data(hashes)]
            root_kids.append(og.group(obj))
            var meta = "schema=" + schema + ";schemaBaseType=AbcGeom_GeomBase_v1;schemaObjTitle=" + schema + ":.geom"
            _put_u32(child_headers, o.name.byte_length())
            _put_str(child_headers, o.name)
            child_headers.append(0xFF)
            _put_u32(child_headers, meta.byte_length())
            _put_str(child_headers, meta)
        for _ in range(32):
            child_headers.append(0)
        root_kids.append(og.data(child_headers))
        var root_obj = og.group(root_kids)
        var ver = List[UInt8]()
        _put_u32(ver, 0)
        var lib = List[UInt8]()
        _put_u32(lib, 10803)
        var meta = List[UInt8]()
        _put_str(meta, "_ai_Application=ludens-engine;FramesPerTimeUnit=" + String(self.fps))
        var ts = List[UInt8]()
        _put_u32(ts, 1)  # identity sampling: 1 s per sample from 0
        _put_f64(ts, 1)
        _put_u32(ts, 1)
        _put_f64(ts, 0)
        _put_u32(ts, max_frames)  # uniform sampling, index 1
        _put_f64(ts, 1 / self.fps)
        _put_u32(ts, 1)
        _put_f64(ts, self.start)
        var archive: List[UInt64] = [
            og.data(ver), og.data(lib), root_obj, og.data(meta), og.data(ts), _DATA_BIT
        ]
        var root = og.group(archive)
        return og.finish(root)


# --- reading (the inverse of `AbcArchive.bytes`) ---


struct AbcObject(Copyable, Movable):
    """One object read back by `abc_read`: per frame, the positions (x, y, z
    per vertex), and for meshes the vertex count of each face and the face
    vertex indices counter-clockwise (as `mesh_frame` was given them); for
    curves the vertex count of each curve; for points the ids. Empty where the
    kind has none."""

    var name: String
    var kind: Int
    var pos: List[List[Float32]]
    var counts: List[List[Int]]
    var indices: List[List[Int]]

    def __init__(out self, var name: String, kind: Int):
        self.name = name^
        self.kind = kind
        self.pos = List[List[Float32]]()
        self.counts = List[List[Int]]()
        self.indices = List[List[Int]]()


struct _RProp(Copyable, Movable):
    var name: String
    var n: Int
    var is_array: Bool
    var constant: Bool

    def __init__(out self, var name: String, n: Int, is_array: Bool, constant: Bool):
        self.name = name^
        self.n = n
        self.is_array = is_array
        self.constant = constant


def _ru(d: List[UInt8], at: Int, n: Int) raises -> UInt64:
    """Little-endian unsigned read of `n` bytes at `at`."""
    if at < 0 or at + n > len(d):
        raise Error("abc_read: truncated file")
    var v = UInt64(0)
    for k in range(n):
        v |= UInt64(d[at + k]) << UInt64(8 * k)
    return v


def _rsized(d: List[UInt8], mut at: Int, hint: Int) raises -> Int:
    var n = 1 if hint == 0 else (2 if hint == 1 else 4)
    var v = Int(_ru(d, at, n))
    at += n
    return v


def _rstr(d: List[UInt8], mut at: Int, n: Int) raises -> String:
    if at < 0 or at + n > len(d):
        raise Error("abc_read: truncated file")
    var s = String()
    for k in range(n):
        s += chr(Int(d[at + k]))
    at += n
    return s


def _rchildren(d: List[UInt8], v: UInt64) raises -> List[UInt64]:
    """The child values of the group at offset `v` (0 is the empty group)."""
    var kids = List[UInt64]()
    if v == 0:
        return kids^
    if v >= UInt64(len(d)):
        raise Error("abc_read: group offset outside the file")
    var off = Int(v)
    var n = Int(_ru(d, off, 8))
    if n > (len(d) - off - 8) // 8:
        raise Error("abc_read: group larger than the file")
    for i in range(n):
        kids.append(_ru(d, off + 8 + 8 * i, 8))
    return kids^


def _rpayload(d: List[UInt8], v: UInt64) raises -> List[UInt8]:
    """The bytes of the data child `v` (the empty data is offset 0)."""
    var off64 = v & ~_DATA_BIT
    var out = List[UInt8]()
    if off64 == 0:
        return out^
    if off64 >= UInt64(len(d)):
        raise Error("abc_read: data offset outside the file")
    var off = Int(off64)
    var size = Int(_ru(d, off, 8))
    if size > len(d) - off - 8:
        raise Error("abc_read: data larger than the file")
    out.reserve(size)
    for k in range(size):
        out.append(d[off + 8 + k])
    return out^


def _rprop(hp: List[UInt8], mut at: Int) raises -> _RProp:
    """One property header in a compound's header block (the writer's
    `_write_prop` layout)."""
    var info = Int(_ru(hp, at, 4))
    at += 4
    var hint = (info >> 2) & 3
    var n = _rsized(hp, at, hint)
    if info & 0x100 != 0:
        _ = _rsized(hp, at, hint)  # time sampling index
    var nl = _rsized(hp, at, hint)
    var name = _rstr(hp, at, nl)
    if (info >> 20) & 0xFF == 0xFF:
        var ml = _rsized(hp, at, hint)
        _ = _rstr(hp, at, ml)
    return _RProp(name, n, info & 3 == 2, info & 0x800 != 0)


def _rsamples(d: List[UInt8], group: UInt64, p: _RProp) raises -> List[List[UInt8]]:
    """The values of each sample of a property group. Each stored sample is a
    data block (a 16-byte key, then the values) and, for arrays, a dimensions
    entry. A constant property stores one sample, repeated `n` times."""
    var out = List[List[UInt8]]()
    var kids = _rchildren(d, group)
    var per = 2 if p.is_array else 1
    var stored = min(1 if p.constant else p.n, p.n)
    if len(kids) != stored * per:
        raise Error("abc_read: property " + p.name + " has the wrong sample count")
    var first = List[UInt8]()
    for i in range(stored):
        var payload = _rpayload(d, kids[i * per])
        if len(payload) < 16:
            raise Error("abc_read: sample without a key")
        var values = List[UInt8]()
        for k in range(16, len(payload)):
            values.append(payload[k])
        if i == 0:
            first = values.copy()
        out.append(values^)
    if p.constant:
        for _ in range(stored, p.n):
            out.append(first.copy())
    return out^


def _rf32(b: List[UInt8], at: Int) raises -> Float32:
    var u = UInt32(_ru(b, at, 4))
    return Pointer(to=u).unsafe_bitcast[Float32]()[]


def _ru32s(b: List[UInt8]) raises -> List[Int]:
    var v = List[Int]()
    for i in range(len(b) // 4):
        v.append(Int(_ru(b, 4 * i, 4)))
    return v^


def _rpoints(b: List[UInt8]) raises -> List[Float32]:
    var v = List[Float32]()
    for i in range(len(b) // 4):
        v.append(_rf32(b, 4 * i))
    return v^


def abc_read(d: List[UInt8]) raises -> List[AbcObject]:
    """The objects of an archive `AbcArchive.bytes` wrote, frame by frame. It
    walks the Ogawa container and the Alembic layout the writer emits; it does
    not read foreign archives written by other tools (a different layout of
    the same container raises, or reads a shape the checks below reject)."""
    if len(d) < 16:
        raise Error("abc_read: not an Ogawa file (too short)")
    var magic_at = 0
    if _rstr(d, magic_at, 5) != "Ogawa" or d[5] != 0xFF:
        raise Error("abc_read: not an Ogawa file (header)")
    var archive = _rchildren(d, _ru(d, 8, 8))
    if len(archive) != 6:
        raise Error("abc_read: archive group has the wrong shape")
    var root_obj = _rchildren(d, archive[2])
    if len(root_obj) < 2:
        raise Error("abc_read: root object group has the wrong shape")
    var nobj = len(root_obj) - 2
    var hdr = _rpayload(d, root_obj[len(root_obj) - 1])
    var out = List[AbcObject]()
    var at = 0
    for i in range(nobj):
        var nl = Int(_ru(hdr, at, 4))
        at += 4
        var name = _rstr(hdr, at, nl)
        at += 1  # metadata index
        var ml = Int(_ru(hdr, at, 4))
        at += 4
        var meta = _rstr(hdr, at, ml)
        var kind = -1
        if "AbcGeom_PolyMesh_v1" in meta:
            kind = ABC_MESH
        elif "AbcGeom_Points_v1" in meta:
            kind = ABC_POINTS
        elif "AbcGeom_Curve_v2" in meta:
            kind = ABC_CURVES
        if kind < 0:
            raise Error("abc_read: object " + name + " is not a mesh, points or curves")
        out.append(AbcObject(name, kind))
        var obj = _rchildren(d, root_obj[1 + i])
        var top = _rchildren(d, obj[0])
        var geom = _rchildren(d, top[0])
        var ghdr = _rpayload(d, geom[len(geom) - 1])
        var nprop = len(geom) - 1
        var names = List[String]()
        var samples = List[List[List[UInt8]]]()
        var gat = 0
        for j in range(nprop):
            var p = _rprop(ghdr, gat)
            names.append(p.name)
            samples.append(_rsamples(d, geom[j], p))
        # the .geom compound's own header is the last group's neighbour; the
        # property order and count per kind is the writer's
        var expect: List[String]
        if kind == ABC_MESH:
            expect = ["P", ".faceIndices", ".faceCounts", ".selfBnds"]
        elif kind == ABC_POINTS:
            expect = ["P", ".pointIds", ".selfBnds"]
        else:
            expect = ["P", "nVertices", "curveBasisAndType", ".selfBnds"]
        if len(names) != len(expect):
            raise Error("abc_read: object " + name + " has the wrong properties")
        for j in range(len(expect)):
            if names[j] != expect[j]:
                raise Error("abc_read: object " + name + " has property " + names[j] + ", expected " + expect[j])
        var frames = len(samples[0])
        for j in range(len(expect)):
            if len(samples[j]) != frames:
                raise Error("abc_read: object " + name + " has properties with different frame counts")
        for f in range(frames):
            out[i].pos.append(_rpoints(samples[0][f]))
            if kind == ABC_MESH:
                var counts = _ru32s(samples[2][f])
                var idx = _ru32s(samples[1][f])
                # the writer stored each face clockwise; reverse each face back
                var ccw = List[Int](capacity=len(idx))
                var at2 = 0
                for c in counts:
                    for k in range(c):
                        ccw.append(idx[at2 + c - 1 - k])
                    at2 += c
                out[i].counts.append(counts^)
                out[i].indices.append(ccw^)
            elif kind == ABC_POINTS:
                var ids = List[Int]()
                ref fb = samples[1][f]
                for q in range(len(fb) // 8):
                    ids.append(Int(_ru(fb, 8 * q, 8)))
                out[i].indices.append(ids^)
            else:
                out[i].counts.append(_ru32s(samples[1][f]))
    return out^
