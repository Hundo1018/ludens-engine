"""Reflection and a type registry (ROADMAP 17.11).

`ComponentType` carries one `comptime ID: Int` and nothing else a tool, a save
file, a network replicator or a script binding could ask about. This module
generates the missing runtime metadata at COMPILE time from the language's
own reflection (`reflect[T]`, Mojo 1.1 prelude): every field's dotted name,
type name, byte offset and size, walked recursively into nested structs.

  `schema_of[T](version)`   -> `TypeSchema` (the table, built once, no
                               hand-written list to fall out of date)
  `write_value` / `read_value` schema-driven binary (de)serialisation
  `write_values` / `read_values` the same, descriptors once per batch
  `TypeRegistry`             schemas by name, plus by-name field get/set on a
                               type-erased address (tools, scripts)

The blob is self-describing: each field is stored with its name, type name
and size, and `read_value` matches stored fields to the CURRENT schema by
name. A field that no longer exists is skipped, a new field keeps the value
the caller passed in (its default), and a field whose type changed is skipped
rather than reinterpreted -- the Unity / Bevy-reflect migration rule, reported
in a `ReadReport` so a loader can decide whether that is acceptable.

Contract: the types walked here are plain data (the ECS storage contract --
components are trivially copied in and out). A leaf is a field whose type
has fewer than two fields of its own (scalars, `SIMD`, `Bool`, fixed arrays);
its bytes are copied as they are. A pointer-owning leaf (`List`, `String`)
would copy an address, not data, so such types must not be given a schema.
"""

from std.sys import size_of
from std.memory import alloc, Layout

# The alloc-typed byte pointer (same idiom as geometry.field.TapePtr):
#  rebuilds it from a type-erased address.
comptime _BytePtr = type_of(alloc[UInt8](Layout[UInt8](count=1)).unsafe_leak())
comptime _MAGIC = 0x4C534348  # "LSCH"


@fieldwise_init
struct FieldInfo(Copyable, Movable):
    var name: String  # dotted path: "rotation.x"
    var type_name: String
    var offset: Int  # bytes from the start of the value
    var size: Int


struct TypeSchema(Copyable, Movable):
    var name: String
    var version: Int
    var size: Int
    var fields: List[FieldInfo]

    def __init__(out self, var name: String, version: Int, size: Int):
        self.name = name^
        self.version = version
        self.size = size
        self.fields = List[FieldInfo]()

    def find(self, name: String) -> Int:
        for i in range(len(self.fields)):
            if self.fields[i].name == name:
                return i
        return -1


def _walk[T: AnyType](prefix: String, base: Int, mut out: List[FieldInfo]):
    comptime names = reflect[T].field_names()
    comptime for i in range(reflect[T].field_count()):
        comptime FT = reflect[T].field_at[i].T
        var nm = prefix + String(materialize[names[i]]())
        var off = base + reflect[T].field_offset[index=i]()
        comptime if reflect[FT].is_struct() and reflect[FT].field_count() >= 2:
            _walk[FT](nm + ".", off, out)
        else:
            out.append(FieldInfo(nm, String(reflect[FT].name()), off, size_of[FT]()))


def schema_of[T: AnyType](version: Int = 1) -> TypeSchema:
    """The field table of `T`, generated from `reflect[T]`."""
    var s = TypeSchema(String(reflect[T].base_name()), version, size_of[T]())
    _walk[T]("", 0, s.fields)
    return s^


# ------------------------------------------------------------- byte stream


def _put_int(mut out: List[UInt8], v: Int):
    var u = UInt64(v)
    for k in range(8):
        out.append(UInt8((u >> UInt64(8 * k)) & 0xFF))


def _put_str(mut out: List[UInt8], s: String):
    var b = s.as_bytes()
    _put_int(out, len(b))
    for k in range(len(b)):
        out.append(b[k])


def _get_int(data: List[UInt8], mut pos: Int) raises -> Int:
    if pos + 8 > len(data):
        raise Error("schema: truncated blob (int)")
    var u = UInt64(0)
    for k in range(8):
        u |= UInt64(data[pos + k]) << UInt64(8 * k)
    pos += 8
    return Int(u)


def _get_str(data: List[UInt8], mut pos: Int) raises -> String:
    var n = _get_int(data, pos)
    if n < 0 or pos + n > len(data):
        raise Error("schema: truncated blob (string)")
    var s = String(unsafe_from_utf8=Span(data)[pos : pos + n])
    pos += n
    return s^


def write_value[T: AnyType](v: T, schema: TypeSchema, mut out: List[UInt8]):
    """Append `v` as a self-describing record. `schema` must be
    `schema_of[T]` (any version number)."""
    var src = Pointer(to=v).unsafe_bitcast[UInt8]()
    _put_int(out, _MAGIC)
    _put_str(out, schema.name)
    _put_int(out, schema.version)
    _put_int(out, len(schema.fields))
    for i in range(len(schema.fields)):
        ref f = schema.fields[i]
        _put_str(out, f.name)
        _put_str(out, f.type_name)
        _put_int(out, f.size)
        for k in range(f.size):
            out.append(src.unsafe_offset(f.offset + k)[])


@fieldwise_init
struct ReadReport(Copyable, Movable):
    var stored_version: Int
    var restored: Int  # fields matched by name + type and copied
    var dropped: Int  # stored fields the current schema no longer has
    var mismatched: Int  # same name, different type or size: skipped
    var defaulted: Int  # current fields absent from the blob: left as passed in


def read_value[T: AnyType](
    mut v: T, schema: TypeSchema, data: List[UInt8], mut pos: Int
) raises -> ReadReport:
    """Read one record written by `write_value` (of this or an older/newer
    version of `T`) into `v`, matching fields by name. Raises on a corrupt or
    truncated blob, or a record of a different type name."""
    if _get_int(data, pos) != _MAGIC:
        raise Error("schema: bad magic")
    var name = _get_str(data, pos)
    if name != schema.name:
        raise Error("schema: record is '" + name + "', expected '" + schema.name + "'")
    var rep = ReadReport(_get_int(data, pos), 0, 0, 0, 0)
    var n = _get_int(data, pos)
    if n < 0:
        raise Error("schema: corrupt field count")
    var seen = List[Bool](length=len(schema.fields), fill=False)
    var dst = Pointer(to=v).unsafe_bitcast[UInt8]()
    for _ in range(n):
        var fname = _get_str(data, pos)
        var tname = _get_str(data, pos)
        var size = _get_int(data, pos)
        if size < 0 or pos + size > len(data):
            raise Error("schema: truncated blob (field bytes)")
        var j = schema.find(fname)
        if j < 0:
            rep.dropped += 1
        elif schema.fields[j].type_name != tname or schema.fields[j].size != size:
            rep.mismatched += 1
            seen[j] = True
        else:
            var off = schema.fields[j].offset
            for k in range(size):
                dst.unsafe_offset(off + k)[] = data[pos + k]
            rep.restored += 1
            seen[j] = True
        pos += size
    for j in range(len(schema.fields)):
        if not seen[j]:
            rep.defaulted += 1
    return rep^


def write_values[T: Copyable](vals: List[T], schema: TypeSchema, mut out: List[UInt8]):
    """Batch form of `write_value`: the field descriptors once, then only
    each value's field bytes -- the per-record self-description is what the
    single-value form pays for (see `bench_schema`)."""
    _put_int(out, _MAGIC + 1)
    _put_str(out, schema.name)
    _put_int(out, schema.version)
    _put_int(out, len(schema.fields))
    for i in range(len(schema.fields)):
        ref f = schema.fields[i]
        _put_str(out, f.name)
        _put_str(out, f.type_name)
        _put_int(out, f.size)
    _put_int(out, len(vals))
    for v in range(len(vals)):
        var src = Pointer(to=vals[v]).unsafe_bitcast[UInt8]()
        for i in range(len(schema.fields)):
            ref f = schema.fields[i]
            for k in range(f.size):
                out.append(src.unsafe_offset(f.offset + k)[])


def read_values[T: Copyable](
    mut out: List[T], template: T, schema: TypeSchema, data: List[UInt8], mut pos: Int
) raises -> ReadReport:
    """Read a `write_values` batch, appending one value per record to `out`.
    Each starts as a copy of `template` (so new fields get its values); the
    name matching of `read_value` is done ONCE for the batch."""
    if _get_int(data, pos) != _MAGIC + 1:
        raise Error("schema: bad batch magic")
    var name = _get_str(data, pos)
    if name != schema.name:
        raise Error("schema: batch is '" + name + "', expected '" + schema.name + "'")
    var rep = ReadReport(_get_int(data, pos), 0, 0, 0, 0)
    var n = _get_int(data, pos)
    if n < 0:
        raise Error("schema: corrupt field count")
    var dst_off = List[Int]()  # per stored field: destination offset, -1 = skip
    var sizes = List[Int]()
    var seen = List[Bool](length=len(schema.fields), fill=False)
    for _ in range(n):
        var fname = _get_str(data, pos)
        var tname = _get_str(data, pos)
        var size = _get_int(data, pos)
        if size < 0:
            raise Error("schema: corrupt field size")
        var j = schema.find(fname)
        if j < 0:
            rep.dropped += 1
            dst_off.append(-1)
        elif schema.fields[j].type_name != tname or schema.fields[j].size != size:
            rep.mismatched += 1
            seen[j] = True
            dst_off.append(-1)
        else:
            rep.restored += 1
            seen[j] = True
            dst_off.append(schema.fields[j].offset)
        sizes.append(size)
    for j in range(len(schema.fields)):
        if not seen[j]:
            rep.defaulted += 1
    var count = _get_int(data, pos)
    var rec = 0
    for i in range(len(sizes)):
        rec += sizes[i]
    if count < 0 or pos + count * rec > len(data):
        raise Error("schema: truncated batch")
    for _ in range(count):
        var v = template.copy()
        var dst = Pointer(to=v).unsafe_bitcast[UInt8]()
        for i in range(len(sizes)):
            if dst_off[i] >= 0:
                for k in range(sizes[i]):
                    dst.unsafe_offset(dst_off[i] + k)[] = data[pos + k]
            pos += sizes[i]
        out.append(v^)
    return rep^


# ---------------------------------------------------------------- registry


struct TypeRegistry(Movable):
    """Schemas by type name, and by-name field access on a type-erased
    address -- what an inspector, a replication layer or a script binding
    needs when it holds bytes and a type name rather than a Mojo type."""

    var schemas: List[TypeSchema]

    def __init__(out self):
        self.schemas = List[TypeSchema]()

    def register[T: AnyType](mut self, version: Int = 1) -> Int:
        var s = schema_of[T](version)
        var i = self.find(s.name)
        if i >= 0:
            self.schemas[i] = s^
            return i
        self.schemas.append(s^)
        return len(self.schemas) - 1

    def find(self, name: String) -> Int:
        for i in range(len(self.schemas)):
            if self.schemas[i].name == name:
                return i
        return -1

    def _field(self, type_name: String, field: String) raises -> FieldInfo:
        var t = self.find(type_name)
        if t < 0:
            raise Error("registry: unknown type '" + type_name + "'")
        var f = self.schemas[t].find(field)
        if f < 0:
            raise Error("registry: " + type_name + " has no field '" + field + "'")
        return self.schemas[t].fields[f].copy()

    def get_f64(self, addr: Int, type_name: String, field: String) raises -> Float64:
        """Read a scalar leaf (float32/float64/int/bool) as Float64."""
        var f = self._field(type_name, field)
        var p = _BytePtr(unsafe_from_address=addr + f.offset)
        if f.type_name == "SIMD[DType.float32, 1]":
            return Float64(p.unsafe_bitcast[Float32]()[])
        if f.type_name == "SIMD[DType.float64, 1]":
            return p.unsafe_bitcast[Float64]()[]
        if f.type_name == "SIMD[DType.int, 1]":
            return Float64(p.unsafe_bitcast[Int]()[])
        if f.type_name == "Bool":
            return Float64(1) if p.unsafe_bitcast[Bool]()[] else Float64(0)
        raise Error("registry: field '" + field + "' is " + f.type_name + ", not a scalar")

    def set_f64(self, addr: Int, type_name: String, field: String, v: Float64) raises:
        var f = self._field(type_name, field)
        var p = _BytePtr(unsafe_from_address=addr + f.offset)
        if f.type_name == "SIMD[DType.float32, 1]":
            p.unsafe_bitcast[Float32]()[] = Float32(v)
        elif f.type_name == "SIMD[DType.float64, 1]":
            p.unsafe_bitcast[Float64]()[] = v
        elif f.type_name == "SIMD[DType.int, 1]":
            p.unsafe_bitcast[Int]()[] = Int(v)
        elif f.type_name == "Bool":
            p.unsafe_bitcast[Bool]()[] = v != 0
        else:
            raise Error("registry: field '" + field + "' is " + f.type_name + ", not a scalar")


def address_of[T: AnyType](ref v: T) -> Int:
    """The type-erased address `TypeRegistry.get_f64/set_f64` take."""
    return Int(Pointer(to=v))
