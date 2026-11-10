"""Node graphs: one data model for every graph type (ludens-engine #20, data layer).

A `GraphType` is a table: node kinds, each with named input and output ports and a signal type per port. A graph type
is data, so adding one (an animation graph, a behaviour tree, a navmesh preview) is registering a table; nothing in this
file knows about animation. A `Graph` holds nodes (id, kind, key = value params) and edges (from node.port to node.port).

Text format (canonical: nodes by id, edges by target then source, params by key; `graph_to_text` of a parsed graph is
byte-identical to canonical input):

    graph anim
    node 1 clip name=walk
    node 2 clip name=run
    node 3 blend2 weight=0.5
    edge 1.out -> 3.a
    edge 2.out -> 3.b

`validate` returns problems, each naming the node: an unknown kind, an edge from a missing port or to a missing port, a
signal type mismatch, an input fed by two edges, a required input with no edge, and a data-flow cycle. `Graph.apply`
edits go through snapshot undo (`GraphHistory`): a graph is small, so a step is the canonical text before the edit, which
is exact and cannot drift from the format. Consecutive `set_param` of the same node and key merge into one step.

Standard library only."""


@fieldwise_init
struct PortDef(Copyable, Movable):
    var name: String
    var signal: String
    var required: Bool


@fieldwise_init
struct KindDef(Copyable, Movable):
    var name: String
    var inputs: List[PortDef]
    var outputs: List[PortDef]


struct GraphType(Copyable, Movable):
    var name: String
    var kinds: List[KindDef]

    def __init__(out self, name: String):
        self.name = name
        self.kinds = List[KindDef]()

    def add_kind(mut self, name: String, ins: List[PortDef], outs: List[PortDef]) raises:
        if self.find(name) >= 0:
            raise Error("graph type `" + self.name + "`: kind `" + name + "` registered twice")
        self.kinds.append(KindDef(name, ins.copy(), outs.copy()))

    def find(self, name: String) -> Int:
        for i in range(len(self.kinds)):
            if self.kinds[i].name == name:
                return i
        return -1


@fieldwise_init
struct Node(Copyable, Movable):
    var id: Int
    var kind: String
    var keys: List[String]
    var vals: List[String]


@fieldwise_init
struct Edge(Copyable, Movable):
    var src: Int
    var src_port: String
    var dst: Int
    var dst_port: String


struct Graph(Copyable, Movable):
    var name: String
    var nodes: List[Node]
    var edges: List[Edge]

    def __init__(out self, name: String):
        self.name = name
        self.nodes = List[Node]()
        self.edges = List[Edge]()

    def node_index(self, id: Int) -> Int:
        for i in range(len(self.nodes)):
            if self.nodes[i].id == id:
                return i
        return -1

    def add_node(mut self, id: Int, kind: String) raises:
        if id < 0 or self.node_index(id) >= 0:
            raise Error("add_node: id " + String(id) + " is negative or already used")
        self.nodes.append(Node(id, kind, List[String](), List[String]()))

    def set_param(mut self, id: Int, key: String, val: String) raises:
        var i = self.node_index(id)
        if i < 0:
            raise Error("set_param: no node " + String(id))
        for k in range(len(self.nodes[i].keys)):
            if self.nodes[i].keys[k] == key:
                self.nodes[i].vals[k] = val
                return
        self.nodes[i].keys.append(key)
        self.nodes[i].vals.append(val)

    def connect(mut self, src: Int, src_port: String, dst: Int, dst_port: String) raises:
        if self.node_index(src) < 0 or self.node_index(dst) < 0:
            raise Error("connect: node " + String(src if self.node_index(src) < 0 else dst) + " does not exist")
        for e in self.edges:
            if e.src == src and e.src_port == src_port and e.dst == dst and e.dst_port == dst_port:
                raise Error("connect: that edge exists")
        self.edges.append(Edge(src, src_port, dst, dst_port))

    def disconnect(mut self, dst: Int, dst_port: String) raises:
        var kept = List[Edge]()
        var found = False
        for e in self.edges:
            if e.dst == dst and e.dst_port == dst_port:
                found = True
            else:
                kept.append(e.copy())
        if not found:
            raise Error("disconnect: nothing feeds " + String(dst) + "." + dst_port)
        self.edges = kept^

    def remove_node(mut self, id: Int) raises:
        var i = self.node_index(id)
        if i < 0:
            raise Error("remove_node: no node " + String(id))
        var nodes = List[Node]()
        for k in range(len(self.nodes)):
            if k != i:
                nodes.append(self.nodes[k].copy())
        self.nodes = nodes^
        var kept = List[Edge]()
        for e in self.edges:
            if e.src != id and e.dst != id:
                kept.append(e.copy())
        self.edges = kept^


def _less_edge(a: Edge, b: Edge) -> Bool:
    if a.dst != b.dst:
        return a.dst < b.dst
    if a.dst_port != b.dst_port:
        return a.dst_port < b.dst_port
    if a.src != b.src:
        return a.src < b.src
    return a.src_port < b.src_port


def graph_to_text(g: Graph) -> String:
    var order = List[Int]()
    for i in range(len(g.nodes)):
        var j = len(order)
        order.append(i)
        while j > 0 and g.nodes[order[j - 1]].id > g.nodes[i].id:
            order[j] = order[j - 1]
            j -= 1
        order[j] = i
    var out = "graph " + g.name + "\n"
    for oi in range(len(order)):
        ref n = g.nodes[order[oi]]
        var ks = List[Int]()
        for i in range(len(n.keys)):
            var j = len(ks)
            ks.append(i)
            while j > 0 and n.keys[ks[j - 1]] > n.keys[i]:
                ks[j] = ks[j - 1]
                j -= 1
            ks[j] = i
        out += "node " + String(n.id) + " " + n.kind
        for k in ks:
            out += " " + n.keys[k] + "=" + n.vals[k]
        out += "\n"
    var eo = List[Int]()
    for i in range(len(g.edges)):
        var j = len(eo)
        eo.append(i)
        while j > 0 and _less_edge(g.edges[i], g.edges[eo[j - 1]]):
            eo[j] = eo[j - 1]
            j -= 1
        eo[j] = i
    for k in eo:
        ref e = g.edges[k]
        out += "edge " + String(e.src) + "." + e.src_port + " -> " + String(e.dst) + "." + e.dst_port + "\n"
    return out^


def _split_port(t: String, line: Int) raises -> Tuple[Int, String]:
    var parts = t.split(".")
    if len(parts) != 2:
        raise Error("line " + String(line) + ": `" + t + "` must be <node>.<port>")
    try:
        return (Int(parts[0]), String(parts[1]))
    except:
        raise Error("line " + String(line) + ": `" + String(parts[0]) + "` is not a node number")


def graph_from_text(text: String) raises -> Graph:
    var g = Graph(String())
    var seen_header = False
    var line_no = 0
    var pend = List[Edge]()
    var pend_line = List[Int]()
    for raw in text.split("\n"):
        line_no += 1
        var line = String(raw.strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var w = List[String]()
        for x in line.split(" "):
            var s = String(x.strip())
            if s.byte_length() > 0:
                w.append(s)
        if w[0] == "graph":
            if len(w) != 2 or seen_header:
                raise Error("line " + String(line_no) + ": expected one `graph <name>` line")
            g.name = w[1]
            seen_header = True
        elif w[0] == "node":
            if len(w) < 3:
                raise Error("line " + String(line_no) + ": node needs <id> <kind>")
            var id: Int
            try:
                id = Int(w[1])
            except:
                raise Error("line " + String(line_no) + ": node id `" + w[1] + "` is not a number")
            try:
                g.add_node(id, w[2])
            except e:
                raise Error("line " + String(line_no) + ": " + String(e))
            for i in range(3, len(w)):
                var kv = w[i].split("=")
                if len(kv) != 2:
                    raise Error("line " + String(line_no) + ": parameter `" + w[i] + "` must be key=value")
                g.set_param(id, String(kv[0]), String(kv[1]))
        elif w[0] == "edge":
            if len(w) != 4 or w[2] != "->":
                raise Error("line " + String(line_no) + ": edge needs <node>.<port> -> <node>.<port>")
            var a = _split_port(w[1], line_no)
            var b = _split_port(w[3], line_no)
            pend.append(Edge(a[0], a[1], b[0], b[1]))  # nodes may come after the edge that names them
            pend_line.append(line_no)
        else:
            raise Error("line " + String(line_no) + ": unknown line start `" + w[0] + "`")
    if not seen_header:
        raise Error("missing `graph <name>` line")
    for i in range(len(pend)):
        try:
            g.connect(pend[i].src, pend[i].src_port, pend[i].dst, pend[i].dst_port)
        except e:
            raise Error("line " + String(pend_line[i]) + ": " + String(e))
    return g^


def _port(ports: List[PortDef], name: String) -> Int:
    for i in range(len(ports)):
        if ports[i].name == name:
            return i
    return -1


def validate(g: Graph, t: GraphType) -> List[String]:
    """Every problem, each naming the node (and the port where it applies). Empty = valid."""
    var out = List[String]()
    for n in g.nodes:
        if t.find(n.kind) < 0:
            out.append("node " + String(n.id) + ": unknown kind `" + n.kind + "` for graph type `" + t.name + "`")
    for e in g.edges:
        var si = g.node_index(e.src)
        var di = g.node_index(e.dst)
        if si < 0 or di < 0:
            continue
        var sk = t.find(g.nodes[si].kind)
        var dk = t.find(g.nodes[di].kind)
        if sk < 0 or dk < 0:
            continue
        var sp = _port(t.kinds[sk].outputs, e.src_port)
        var dp = _port(t.kinds[dk].inputs, e.dst_port)
        if sp < 0:
            out.append("node " + String(e.src) + ": has no output `" + e.src_port + "`")
        if dp < 0:
            out.append("node " + String(e.dst) + ": has no input `" + e.dst_port + "`")
        if sp >= 0 and dp >= 0 and t.kinds[sk].outputs[sp].signal != t.kinds[dk].inputs[dp].signal:
            out.append("node " + String(e.dst) + ": input `" + e.dst_port + "` takes `" + t.kinds[dk].inputs[dp].signal + "` but node " + String(e.src) + " gives `" + t.kinds[sk].outputs[sp].signal + "`")
    for i in range(len(g.edges)):
        for j in range(i + 1, len(g.edges)):
            if g.edges[i].dst == g.edges[j].dst and g.edges[i].dst_port == g.edges[j].dst_port:
                out.append("node " + String(g.edges[i].dst) + ": input `" + g.edges[i].dst_port + "` is fed by two edges")
    for n in g.nodes:
        var k = t.find(n.kind)
        if k < 0:
            continue
        for p in t.kinds[k].inputs:
            if p.required:
                var fed = False
                for e in g.edges:
                    if e.dst == n.id and e.dst_port == p.name:
                        fed = True
                if not fed:
                    out.append("node " + String(n.id) + ": required input `" + p.name + "` has no edge")
    # data-flow cycle: repeatedly drop nodes with no incoming edge from a remaining node
    var alive = List[Bool]()
    for _ in range(len(g.nodes)):
        alive.append(True)
    var changed = True
    while changed:
        changed = False
        for i in range(len(g.nodes)):
            if not alive[i]:
                continue
            var has_in = False
            for e in g.edges:
                if e.dst == g.nodes[i].id:
                    var si = g.node_index(e.src)
                    if si >= 0 and alive[si]:
                        has_in = True
            if not has_in:
                alive[i] = False
                changed = True
    for i in range(len(g.nodes)):
        if alive[i]:
            out.append("node " + String(g.nodes[i].id) + ": is part of, or fed by, a cycle")
    return out^


struct GraphHistory(Movable):
    """Snapshot undo for one graph: the canonical text before each edit."""
    var past: List[String]
    var future: List[String]
    var last_key: String  # "<node>:<param>" of the last set_param, "" otherwise

    def __init__(out self):
        self.past = List[String]()
        self.future = List[String]()
        self.last_key = String()

    def record(mut self, g: Graph, merge_key: String = String()):
        """Call before an edit. A non-empty `merge_key` equal to the previous edit's merges into that step."""
        if merge_key.byte_length() > 0 and merge_key == self.last_key and len(self.past) > 0:
            return
        self.past.append(graph_to_text(g))
        self.future = List[String]()
        self.last_key = merge_key

    def undo(mut self, mut g: Graph) raises -> Bool:
        if len(self.past) == 0:
            return False
        self.future.append(graph_to_text(g))
        g = graph_from_text(self.past.pop())
        self.last_key = String()
        return True

    def redo(mut self, mut g: Graph) raises -> Bool:
        if len(self.future) == 0:
            return False
        self.past.append(graph_to_text(g))
        g = graph_from_text(self.future.pop())
        self.last_key = String()
        return True
