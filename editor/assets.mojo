"""The asset database (ludens-shell #12): sources, import settings, artifacts, identified by content hash.

An asset is a source file plus the settings it is imported with. Its key is the SHA-256 of both; the importer chosen by
the file extension (`editor.ext.ImporterRegistry`, #18) turns the source into an artifact, and the artifact is
identified by its own SHA-256. A scene (#9) refers to an asset by that artifact hash.

`AssetDb.build` is incremental: an asset whose key and importer are unchanged is not imported again, and an asset that
lists another as a dependency is rebuilt when that one's artifact changed. It returns the rebuild log (the paths it
imported, in build order) so a test or a person can see exactly what was redone. A source the importer rejects is
recorded as failed with the reason and does not stop the build; its previous artifact (if any) is dropped. The output
is deterministic: assets are processed in sorted path order, and `manifest()` is a byte-exact text listing, so building
the same inputs twice gives identical bytes.

Standard library plus the extension API only."""
from editor.ext import Importer, ImporterRegistry


# ---------------------------------------------------------------- SHA-256

def _k() -> List[UInt32]:
    var k = List[UInt32]()
    k.append(0x428A2F98)
    k.append(0x71374491)
    k.append(0xB5C0FBCF)
    k.append(0xE9B5DBA5)
    k.append(0x3956C25B)
    k.append(0x59F111F1)
    k.append(0x923F82A4)
    k.append(0xAB1C5ED5)
    k.append(0xD807AA98)
    k.append(0x12835B01)
    k.append(0x243185BE)
    k.append(0x550C7DC3)
    k.append(0x72BE5D74)
    k.append(0x80DEB1FE)
    k.append(0x9BDC06A7)
    k.append(0xC19BF174)
    k.append(0xE49B69C1)
    k.append(0xEFBE4786)
    k.append(0x0FC19DC6)
    k.append(0x240CA1CC)
    k.append(0x2DE92C6F)
    k.append(0x4A7484AA)
    k.append(0x5CB0A9DC)
    k.append(0x76F988DA)
    k.append(0x983E5152)
    k.append(0xA831C66D)
    k.append(0xB00327C8)
    k.append(0xBF597FC7)
    k.append(0xC6E00BF3)
    k.append(0xD5A79147)
    k.append(0x06CA6351)
    k.append(0x14292967)
    k.append(0x27B70A85)
    k.append(0x2E1B2138)
    k.append(0x4D2C6DFC)
    k.append(0x53380D13)
    k.append(0x650A7354)
    k.append(0x766A0ABB)
    k.append(0x81C2C92E)
    k.append(0x92722C85)
    k.append(0xA2BFE8A1)
    k.append(0xA81A664B)
    k.append(0xC24B8B70)
    k.append(0xC76C51A3)
    k.append(0xD192E819)
    k.append(0xD6990624)
    k.append(0xF40E3585)
    k.append(0x106AA070)
    k.append(0x19A4C116)
    k.append(0x1E376C08)
    k.append(0x2748774C)
    k.append(0x34B0BCB5)
    k.append(0x391C0CB3)
    k.append(0x4ED8AA4A)
    k.append(0x5B9CCA4F)
    k.append(0x682E6FF3)
    k.append(0x748F82EE)
    k.append(0x78A5636F)
    k.append(0x84C87814)
    k.append(0x8CC70208)
    k.append(0x90BEFFFA)
    k.append(0xA4506CEB)
    k.append(0xBEF9A3F7)
    k.append(0xC67178F2)
    return k^


def _rotr(x: UInt32, n: UInt32) -> UInt32:
    return (x >> n) | (x << (32 - n))


def sha256(data: List[UInt8]) -> String:
    """Lower-case hex SHA-256 of `data`."""
    var h = List[UInt32]()
    h.append(0x6A09E667)
    h.append(0xBB67AE85)
    h.append(0x3C6EF372)
    h.append(0xA54FF53A)
    h.append(0x510E527F)
    h.append(0x9B05688C)
    h.append(0x1F83D9AB)
    h.append(0x5BE0CD19)
    var K = _k()
    var msg = data.copy()
    var bit_len = UInt64(len(data)) * 8
    msg.append(0x80)
    while len(msg) % 64 != 56:
        msg.append(0)
    for k in range(8):
        msg.append(UInt8((bit_len >> UInt64(56 - 8 * k)) & 0xFF))
    var w = List[UInt32](length=64, fill=0)
    for block in range(len(msg) // 64):
        for t in range(16):
            var o = block * 64 + t * 4
            w[t] = (UInt32(msg[o]) << 24) | (UInt32(msg[o + 1]) << 16) | (UInt32(msg[o + 2]) << 8) | UInt32(msg[o + 3])
        for t in range(16, 64):
            var s0 = _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
            var s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
            w[t] = w[t - 16] + s0 + w[t - 7] + s1
        var a = h[0]
        var b = h[1]
        var c = h[2]
        var d = h[3]
        var e = h[4]
        var f = h[5]
        var g = h[6]
        var hh = h[7]
        for t in range(64):
            var S1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25)
            var ch = (e & f) ^ (~e & g)
            var t1 = hh + S1 + ch + K[t] + w[t]
            var S0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22)
            var maj = (a & b) ^ (a & c) ^ (b & c)
            var t2 = S0 + maj
            hh = g
            g = f
            f = e
            e = d + t1
            d = c
            c = b
            b = a
            a = t1 + t2
        h[0] += a
        h[1] += b
        h[2] += c
        h[3] += d
        h[4] += e
        h[5] += f
        h[6] += g
        h[7] += hh
    var hex = "0123456789abcdef"
    var out = String()
    for i in range(8):
        for sh in range(8):
            var nib = Int((h[i] >> UInt32(28 - 4 * sh)) & 0xF)
            out += String(hex[byte=nib])
    return out^


def sha256_text(s: String) -> String:
    var b = List[UInt8]()
    for c in s.as_bytes():
        b.append(c)
    return sha256(b)


# --------------------------------------------------------------------- db

comptime MAX_SOURCE_BYTES = 256 * 1024 * 1024

comptime STATUS_OK = 0
comptime STATUS_FAILED = 1


@fieldwise_init
struct SourceFile(Copyable, Movable):
    """What a build is given: the path (relative, `/`-separated), the bytes, the import settings text, and the paths
    of other assets this one depends on (rebuilt when their artifacts change)."""
    var path: String
    var data: List[UInt8]
    var settings: String
    var deps: List[String]


@fieldwise_init
struct AssetEntry(Copyable, Movable):
    var path: String
    var key: String  # sha256(source bytes, settings)
    var artifact_hash: String  # sha256 of the artifact; empty when the import failed
    var artifact: List[UInt8]
    var status: Int
    var error: String
    var deps: List[String]
    var dep_hashes: String  # the artifact hashes of the deps at the time of the build, joined


struct AssetDb(Movable):
    var entries: List[AssetEntry]  # sorted by path

    def __init__(out self):
        self.entries = List[AssetEntry]()

    def find(self, path: String) -> Int:
        for i in range(len(self.entries)):
            if self.entries[i].path == path:
                return i
        return -1

    def artifact_hash(self, path: String) -> String:
        var i = self.find(path)
        return self.entries[i].artifact_hash if i >= 0 else String()

    def manifest(self) -> String:
        """One line per asset in path order: `path key artifact status`. Byte-exact for equal inputs."""
        var out = String()
        for i in range(len(self.entries)):
            ref e = self.entries[i]
            out += e.path + " " + e.key + " " + (e.artifact_hash if e.status == STATUS_OK else String("FAILED")) + "\n"
        return out^

    def build[*Is: Importer](mut self, var sources: List[SourceFile]) raises -> List[String]:
        """Import what changed and drop what is gone. Returns the paths imported this time, in order."""
        # sort sources by path (insertion sort: deterministic, the lists are small)
        var order = List[Int]()
        for i in range(len(sources)):
            var j = len(order)
            order.append(i)
            while j > 0 and sources[order[j - 1]].path > sources[i].path:
                order[j] = order[j - 1]
                j -= 1
            order[j] = i
        for a in range(len(order)):
            for b in range(a + 1, len(order)):
                if sources[order[a]].path == sources[order[b]].path:
                    raise Error("assets: path `" + sources[order[a]].path + "` given twice")
        var log = List[String]()
        var next = List[AssetEntry]()
        # dependencies must be built first: repeat passes until no pending source remains (cycles are an error)
        var done = List[Bool]()
        for _ in range(len(order)):
            done.append(False)
        var remaining = len(order)
        while remaining > 0:
            var progressed = False
            for oi in range(len(order)):
                if done[oi]:
                    continue
                ref src = sources[order[oi]]
                var ready = True
                for d in src.deps:
                    var known = False
                    for oj in range(len(order)):
                        if sources[order[oj]].path == d:
                            known = True
                            if not done[oj]:
                                ready = False
                    if not known:
                        raise Error("assets: `" + src.path + "` depends on `" + d + "`, which is not a source")
                if not ready:
                    continue
                self._build_one[*Is](src, next, log)
                done[oi] = True
                remaining -= 1
                progressed = True
            if not progressed:
                raise Error("assets: dependency cycle among the remaining sources")
        # keep entries sorted by path
        var sorted_entries = List[AssetEntry]()
        for oi in range(len(order)):
            var p = sources[order[oi]].path
            for k in range(len(next)):
                if next[k].path == p:
                    sorted_entries.append(next[k].copy())
        self.entries = sorted_entries^
        return log^

    def _build_one[*Is: Importer](self, src: SourceFile, mut built: List[AssetEntry], mut log: List[String]) raises:
        var blob = src.data.copy()
        for c in ("\0" + src.settings).as_bytes():
            blob.append(c)
        var key = sha256(blob)
        var dep_hashes = String()
        for d in src.deps:
            var h = String()
            for k in range(len(built)):
                if built[k].path == d:
                    h = built[k].artifact_hash if built[k].status == STATUS_OK else String("FAILED")
            dep_hashes += d + "=" + h + ";"
        var old = self.find(src.path)
        if old >= 0 and self.entries[old].key == key and self.entries[old].dep_hashes == dep_hashes:
            built.append(self.entries[old].copy())
            return
        log.append(src.path)
        var entry = AssetEntry(src.path, key, String(), List[UInt8](), STATUS_FAILED, String(), src.deps.copy(), dep_hashes)
        if len(src.data) > MAX_SOURCE_BYTES:
            entry.error = "source is larger than " + String(MAX_SOURCE_BYTES) + " bytes"
        elif len(src.data) == 0:
            entry.error = "source is empty"
        else:
            try:
                var art = ImporterRegistry[*Is].import_file(src.path, src.data)
                entry.artifact_hash = sha256(art)
                entry.artifact = art^
                entry.status = STATUS_OK
            except e:
                entry.error = String(e)
        built.append(entry^)
