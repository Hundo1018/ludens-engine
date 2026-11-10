"""Node graph data layer (ludens-engine #20): a table-driven graph type, canonical text, validation that names nodes,
snapshot undo with drag merging, and a second graph type added by registration only. Native only, no GPU.
`pixi run -e wasm test-editor`."""
from editor.graph import Graph, GraphHistory, GraphType, PortDef, graph_from_text, graph_to_text, validate


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


def ports(*names: String) -> List[PortDef]:
    var out = List[PortDef]()
    for n in names:
        out.append(PortDef(n, String("pose"), True))
    return out^


def anim_type() raises -> GraphType:
    var t = GraphType("animation")
    t.add_kind("clip", List[PortDef](), ports("out"))
    t.add_kind("blend2", ports("a", "b"), ports("out"))
    t.add_kind("output", ports("pose"), List[PortDef]())
    var fl = List[PortDef]()
    fl.append(PortDef(String("v"), String("float"), True))
    t.add_kind("speed", List[PortDef](), fl.copy())
    var wi = List[PortDef]()
    wi.append(PortDef(String("a"), String("pose"), True))
    wi.append(PortDef(String("b"), String("pose"), True))
    wi.append(PortDef(String("weight"), String("float"), False))
    t.add_kind("blend_w", wi, ports("out"))
    return t^


def has(problems: List[String], needle: String) -> Bool:
    for p in problems:
        if needle in p:
            return True
    return False


def main() raises:
    var c = Check()
    var t = anim_type()
    var text = String(
        "graph anim\n"
        "node 1 clip name=walk\n"
        "node 2 clip name=run\n"
        "node 3 clip name=idle\n"
        "node 4 blend2\n"
        "node 5 blend2\n"
        "node 6 output\n"
        "node 7 speed value=1.5\n"
        "node 8 blend_w\n"
        "edge 1.out -> 4.a\n"
        "edge 2.out -> 4.b\n"
        "edge 4.out -> 5.a\n"
        "edge 3.out -> 5.b\n"
        "edge 5.out -> 6.pose\n"
        "edge 3.out -> 8.a\n"
        "edge 1.out -> 8.b\n"
        "edge 7.v -> 8.weight\n"
    )
    var g = graph_from_text(text)
    c.ok(len(g.nodes) == 8 and len(g.edges) == 8, "parsed 8 nodes and 8 edges")
    c.ok(graph_to_text(g) == text, "canonical text round-trips byte for byte")
    var shuffled = String("graph anim\nnode 3 clip name=idle\nnode 1 clip name=walk\nedge 3.out -> 5.b\nnode 5 blend2\nedge 1.out -> 5.a\n")
    c.ok(graph_to_text(graph_from_text(shuffled)) == "graph anim\nnode 1 clip name=walk\nnode 3 clip name=idle\nnode 5 blend2\nedge 1.out -> 5.a\nedge 3.out -> 5.b\n", "any order in, canonical order out")
    var base_problems = validate(g, t)
    c.ok(len(base_problems) == 0, "the 8-node, 8-edge graph is valid (0 problems), the float edge 7.v -> 8.weight included")
    g.disconnect(8, "weight")
    c.ok(len(validate(g, t)) == 0, "the optional float input may stay unconnected (still 0 problems)")
    g.connect(7, "v", 8, "weight")

    # invalid graphs name the node
    var bad = graph_from_text(text)
    bad.disconnect(5, "a")
    c.ok(has(validate(bad, t), "node 5: required input `a` has no edge"), "missing input names node 5 and the port")
    var cyc = graph_from_text("graph c\nnode 1 blend2\nnode 2 blend2\nedge 1.out -> 2.a\nedge 2.out -> 1.a\n")
    c.ok(has(validate(cyc, t), "node 1: is part of, or fed by, a cycle") and has(validate(cyc, t), "node 2: is part of"), "a data-flow cycle names its nodes")
    var mism = graph_from_text("graph m\nnode 1 speed\nnode 2 output\nedge 1.v -> 2.pose\n")
    c.ok(has(validate(mism, t), "node 2: input `pose` takes `pose` but node 1 gives `float`"), "a signal type mismatch names both nodes")
    var two = graph_from_text("graph t\nnode 1 clip\nnode 2 clip\nnode 3 output\nedge 1.out -> 3.pose\nedge 2.out -> 3.pose\n")
    c.ok(has(validate(two, t), "node 3: input `pose` is fed by two edges"), "two edges into one input")
    var unk = graph_from_text("graph u\nnode 9 teleport\n")
    c.ok(has(validate(unk, t), "node 9: unknown kind `teleport`"), "unknown kind names the node")
    var noport = graph_from_text("graph p\nnode 1 clip\nnode 2 output\nedge 1.nope -> 2.pose\n")
    c.ok(has(validate(noport, t), "node 1: has no output `nope`"), "an edge from a port that does not exist")

    # parse errors name the line
    var named = True
    var msgs = List[String]()
    msgs.append("graph a\nnode x clip\n")
    msgs.append("graph a\nnode 1 clip\nnode 1 clip\n")
    msgs.append("graph a\nedge 1.out > 2.in\n")
    msgs.append("node 1 clip\n")
    msgs.append("graph a\nnode 1 clip foo\n")
    for m in msgs:
        try:
            _ = graph_from_text(m)
            named = False
        except e:
            if not (("line" in String(e)) or ("missing" in String(e))):
                named = False
    c.ok(named, "5 malformed texts are refused with a line number or the missing header named")

    # undo: structural edits and a merged drag
    var h = GraphHistory()
    var e0 = graph_to_text(g)
    h.record(g)
    g.remove_node(4)
    c.ok(len(g.nodes) == 7 and len(g.edges) == 5, "removing node 4 removed its 3 edges too (1.out, 2.out in; 4.out out)")
    h.record(g, "7:value")
    g.set_param(7, "value", "2.0")
    h.record(g, "7:value")
    g.set_param(7, "value", "2.5")
    h.record(g, "7:value")
    g.set_param(7, "value", "3.0")
    c.ok(len(h.past) == 2, "three edits of the same param are one step (a drag): 2 steps in all")
    c.ok(h.undo(g) and graph_to_text(g).find("value=1.5") >= 0, "undo of the drag restores value=1.5 in one step")
    c.ok(h.undo(g) and graph_to_text(g) == e0, "undo of the removal restores the exact text")
    c.ok(not h.undo(g), "nothing left to undo")
    c.ok(h.redo(g) and h.redo(g) and graph_to_text(g).find("value=3.0") >= 0, "redo twice reaches the final state")
    h.record(g)
    g.add_node(20, "clip")
    c.ok(not h.redo(g), "a new edit ends the redo chain")

    # a second graph type is only a table
    var bt = GraphType("behaviour")
    var seq = List[PortDef]()
    seq.append(PortDef(String("child"), String("status"), True))
    var st = List[PortDef]()
    st.append(PortDef(String("status"), String("status"), True))
    bt.add_kind("root", seq.copy(), List[PortDef]())
    bt.add_kind("action", List[PortDef](), st.copy())
    var bg = graph_from_text("graph bt\nnode 1 root\nnode 2 action name=jump\nedge 2.status -> 1.child\n")
    c.ok(len(validate(bg, bt)) == 0 and len(validate(bg, t)) == 2, "a 2-kind behaviour type validates its graph with no code change; the animation type rejects the same graph")

    print("graph:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("graph: " + String(c.failed) + " checks failed")
