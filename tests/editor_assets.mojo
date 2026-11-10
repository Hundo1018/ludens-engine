"""Asset database (ludens-engine #12): SHA-256 vectors, determinism, incremental rebuild, dependencies, bad input.
Native only, no GPU. `pixi run -e wasm test-editor`."""
from editor.assets import AssetDb, SourceFile, STATUS_FAILED, STATUS_OK, sha256, sha256_text
from editor.ext import Importer


struct Upper(Importer):
    """Source text to upper case: stands in for a real importer."""
    def __init__(out self):
        pass

    @staticmethod
    def extension() -> String:
        return "txt"

    def import_file(self, data: List[UInt8]) raises -> List[UInt8]:
        var out = List[UInt8]()
        for b in data:
            out.append(b - 32 if b >= 97 and b <= 122 else b)
        return out^


struct Strict(Importer):
    """Rejects any source that contains a `!`."""
    def __init__(out self):
        pass

    @staticmethod
    def extension() -> String:
        return "chk"

    def import_file(self, data: List[UInt8]) raises -> List[UInt8]:
        for b in data:
            if b == 33:
                raise Error("strict: found a `!`")
        return data.copy()


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
            print("  [PASS]", label)
        else:
            self.failed += 1
            print("  [FAIL]", label)


def bytes(s: String) -> List[UInt8]:
    var b = List[UInt8]()
    for c in s.as_bytes():
        b.append(c)
    return b^


def src(path: String, text: String, settings: String = "", dep: String = "") -> SourceFile:
    var deps = List[String]()
    if dep != "":
        deps.append(dep)
    return SourceFile(path, bytes(text), settings, deps^)


def has(log: List[String], p: String) -> Bool:
    for x in log:
        if x == p:
            return True
    return False


def sources(a: String, b: String, c: String) -> List[SourceFile]:
    var l = List[SourceFile]()
    l.append(src("b.txt", b))
    l.append(src("a.txt", a))
    l.append(src("scene/c.txt", c, "", "a.txt"))  # c depends on a
    return l^


def main() raises:
    var c = Check()

    # SHA-256 known vectors (FIPS 180-4 / NIST)
    c.ok(sha256_text("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 of the empty string")
    c.ok(sha256_text("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 of abc")
    c.ok(sha256_text("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha256 of the 56-byte NIST vector (two blocks)")
    var million = List[UInt8]()
    for _ in range(1000000):
        million.append(97)
    c.ok(sha256(million) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "sha256 of a million a")

    # first build imports everything, dependencies first, in a deterministic order
    var db = AssetDb()
    var log = db.build[Upper, Strict](sources("alpha", "beta", "gamma"))
    c.ok(len(log) == 3 and log[0] == "a.txt" and log[1] == "b.txt" and log[2] == "scene/c.txt", "first build imports all three in sorted path order")
    c.ok(db.entries[0].artifact == bytes("ALPHA") and db.entries[0].status == STATUS_OK, "the artifact is the importer's output")
    c.ok(db.artifact_hash("a.txt") == sha256_text("ALPHA"), "the artifact hash is the SHA-256 of the artifact")

    # determinism: the same inputs in another order, built from scratch, give the same manifest bytes
    var db2 = AssetDb()
    var l2 = List[SourceFile]()
    l2.append(src("scene/c.txt", "gamma", "", "a.txt"))
    l2.append(src("a.txt", "alpha"))
    l2.append(src("b.txt", "beta"))
    _ = db2.build[Upper, Strict](l2^)
    c.ok(db.manifest() == db2.manifest(), "same inputs, any order, a second database: identical manifest bytes")

    # nothing changed: nothing rebuilt
    log = db.build[Upper, Strict](sources("alpha", "beta", "gamma"))
    c.ok(len(log) == 0, "unchanged inputs: empty rebuild log")

    # a source changes: it and its dependent are rebuilt, the unrelated one is not
    log = db.build[Upper, Strict](sources("ALPHA2", "beta", "gamma"))
    c.ok(len(log) == 2 and has(log, "a.txt") and has(log, "scene/c.txt") and not has(log, "b.txt"), "changed source: it and its dependent are rebuilt, the unrelated asset is not")

    # a dependent whose dependency's artifact did not change is not rebuilt (source differs only in case -> same artifact)
    log = db.build[Upper, Strict](sources("alpha2", "beta", "gamma"))
    c.ok(len(log) == 1 and log[0] == "a.txt", "dependency rebuilt but its artifact is equal: the dependent is not rebuilt")

    # settings are part of the key
    var l3 = sources("alpha2", "beta", "gamma")
    l3[1] = src("a.txt", "alpha2", "quality=high")
    log = db.build[Upper, Strict](l3^)
    c.ok(has(log, "a.txt"), "changed import settings rebuild the asset")

    # bad input: empty, rejected by the importer, no importer, duplicate path; the build continues
    var l4 = sources("alpha2", "beta", "gamma")
    l4.append(src("bad.chk", "no! way"))
    l4.append(src("empty.txt", ""))
    l4.append(src("model.fbx", "x"))
    var db3 = AssetDb()
    log = db3.build[Upper, Strict](l4^)
    var bad = db3.find("bad.chk")
    var emp = db3.find("empty.txt")
    var fbx = db3.find("model.fbx")
    c.ok(bad >= 0 and db3.entries[bad].status == STATUS_FAILED and "strict" in db3.entries[bad].error, "a source the importer rejects is recorded as failed with its reason")
    c.ok(emp >= 0 and db3.entries[emp].status == STATUS_FAILED and "empty" in db3.entries[emp].error, "an empty source is recorded as failed")
    c.ok(fbx >= 0 and db3.entries[fbx].status == STATUS_FAILED and "no importer" in db3.entries[fbx].error, "no importer for the extension: failed, named")
    c.ok(db3.find("a.txt") >= 0 and db3.entries[db3.find("a.txt")].status == STATUS_OK, "the failures did not stop the good assets")
    c.ok("FAILED" in db3.manifest(), "failed assets show in the manifest")
    var dup = sources("a", "b", "c")
    dup.append(src("a.txt", "again"))
    var raised = False
    try:
        var dd = AssetDb()
        _ = dd.build[Upper, Strict](dup^)
    except:
        raised = True
    c.ok(raised, "the same path twice is an error")
    var cyc = List[SourceFile]()
    cyc.append(src("x.txt", "x", "", "y.txt"))
    cyc.append(src("y.txt", "y", "", "x.txt"))
    raised = False
    try:
        var dc = AssetDb()
        _ = dc.build[Upper, Strict](cyc^)
    except e:
        raised = "cycle" in String(e)
    c.ok(raised, "a dependency cycle is an error")
    var missing = List[SourceFile]()
    missing.append(src("x.txt", "x", "", "nope.txt"))
    raised = False
    try:
        var dm = AssetDb()
        _ = dm.build[Upper, Strict](missing^)
    except e:
        raised = "not a source" in String(e)
    c.ok(raised, "a dependency that is not a source is an error")

    # a removed source leaves the database
    var l5 = List[SourceFile]()
    l5.append(src("b.txt", "beta"))
    _ = db.build[Upper, Strict](l5^)
    c.ok(len(db.entries) == 1 and db.find("a.txt") < 0, "a source that is gone leaves the database")

    # hot reload: a bad edit keeps the previous good artifact and reports the reason
    var hr = AssetDb()
    var good = List[SourceFile]()
    good.append(src("level.chk", "ok data"))
    good.append(src("copy.txt", "uses level", "", "level.chk"))
    _ = hr.build[Upper, Strict](good^, True)
    var good_hash = hr.artifact_hash("level.chk")
    var dep_hash = hr.artifact_hash("copy.txt")
    var bad_edit = List[SourceFile]()
    bad_edit.append(src("level.chk", "broken! data"))
    bad_edit.append(src("copy.txt", "uses level", "", "level.chk"))
    var log6 = hr.build[Upper, Strict](bad_edit^, True)
    c.ok(hr.artifact_hash("level.chk") == good_hash and hr.entries[hr.find("level.chk")].status == STATUS_OK, "a failed re-import keeps the previous artifact")
    c.ok(len(hr.errors) == 1 and "level.chk" in hr.errors[0] and "strict" in hr.errors[0], "...and the reason is reported (" + (hr.errors[0] if len(hr.errors) > 0 else String("none")) + ")")
    c.ok(has(log6, "level.chk") and not has(log6, "copy.txt") and hr.artifact_hash("copy.txt") == dep_hash, "...the dependent is not rebuilt, since its dependency's artifact did not change")
    var plain_fail = AssetDb()
    var g2 = List[SourceFile]()
    g2.append(src("level.chk", "ok data"))
    _ = plain_fail.build[Upper, Strict](g2^)
    var b2 = List[SourceFile]()
    b2.append(src("level.chk", "broken! data"))
    _ = plain_fail.build[Upper, Strict](b2^)
    c.ok(plain_fail.entries[0].status == STATUS_FAILED, "control: without keep_on_failure the same bad edit drops the artifact")
    var fixed = List[SourceFile]()
    fixed.append(src("level.chk", "fixed data"))
    fixed.append(src("copy.txt", "uses level", "", "level.chk"))
    var log7 = hr.build[Upper, Strict](fixed^, True)
    c.ok(len(hr.errors) == 0 and hr.artifact_hash("level.chk") != good_hash and has(log7, "copy.txt"), "a later good edit replaces the artifact, clears the errors and rebuilds the dependent")
    var first_bad = List[SourceFile]()
    first_bad.append(src("new.chk", "bad! from the start"))
    var hr2 = AssetDb()
    _ = hr2.build[Upper, Strict](first_bad^, True)
    c.ok(hr2.entries[0].status == STATUS_FAILED and len(hr2.errors) == 0, "an asset that never imported has nothing to keep: it is recorded as failed")

    print("editor-assets:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("editor-assets: " + String(c.failed) + " checks failed")
