"""Localisation keys (ROADMAP 17.73).

The engine holds no text. Game state refers to strings by stable key ids:
the FNV-1a 32 hash of the key name, the same in every build and on every
machine. `LocKeys` registers the names a game uses (a collision between two
names raises at registration), and `missing(table)` lists the registered
ids absent from a host's string table - the check a build step runs.
"""


def loc_id(name: String) -> Int:
    var h = UInt32(0x811C9DC5)
    for c in name.as_bytes():
        h ^= UInt32(c)
        h *= UInt32(0x01000193)
    return Int(h)


struct LocKeys(Copyable, Movable):
    var names: List[String]
    var ids: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.ids = List[Int]()

    def register(mut self, name: String) raises -> Int:
        var id = loc_id(name)
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                if self.names[i] == name:
                    return id
                raise Error("LocKeys: '" + name + "' and '" + self.names[i] + "' hash to the same id")
        self.names.append(name)
        self.ids.append(id)
        return id

    def missing(self, table: List[Int]) -> List[String]:
        var out = List[String]()
        for i in range(len(self.ids)):
            var found = False
            for t in table:
                if t == self.ids[i]:
                    found = True
                    break
            if not found:
                out.append(self.names[i])
        return out^
