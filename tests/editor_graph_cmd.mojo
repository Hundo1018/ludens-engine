"""Node graph commands (ludens-engine #20): through the registry, one undo history with the world's and the curve's,
drag merging, failures leave graph and history alone. Native only, no GPU. `pixi run -e wasm test-editor`."""
from editor.builtin import MoveBody
from editor.builtin_curve import CurveAdd, CurveDelete, CurveMove
from editor.builtin_graph import GraphAdd, GraphConnect, GraphDisconnect, GraphRemove, GraphSet
from editor.entry import cli_run
from editor.graph import graph_to_text
from editor.state import Editor
from embed.world import EmbedWorld
from geometry.vec import Real, Vec3


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


def cmd(mut ed: Editor, *words: String) raises:
    var argv = List[String]()
    for w in words:
        argv.append(w)
    cli_run[MoveBody, CurveAdd, CurveMove, CurveDelete, GraphAdd, GraphSet, GraphConnect, GraphDisconnect, GraphRemove](ed, argv)


def fails(mut ed: Editor, *words: String) -> Bool:
    var argv = List[String]()
    for w in words:
        argv.append(w)
    try:
        cli_run[MoveBody, CurveAdd, CurveMove, CurveDelete, GraphAdd, GraphSet, GraphConnect, GraphDisconnect, GraphRemove](ed, argv)
    except:
        return True
    return False


def main() raises:
    var c = Check()
    var w = EmbedWorld(1.0 / 60.0, Vec3(0.0, -9.81, 0.0, 0.0))
    var ball = w.add_sphere(Vec3(0.0, 2.0, 0.0, 0.0), 0.3, 1.0, False)
    var ed = Editor(w^)
    var empty = graph_to_text(ed.graph)

    cmd(ed, "graph_add", "1", "clip")
    cmd(ed, "graph_add", "2", "blend2")
    cmd(ed, "graph_connect", "1.out", "2.a")
    cmd(ed, "graph_set", "1", "name", "walk")
    c.ok(graph_to_text(ed.graph) == "graph graph\nnode 1 clip name=walk\nnode 2 blend2\nedge 1.out -> 2.a\n", "four commands built the graph")
    var built = graph_to_text(ed.graph)

    # one history with the world and the curve
    cmd(ed, "curve_add", "1", "2", "3")
    cmd(ed, "move_body", String(ball), "1", "2", "0")
    cmd(ed, "graph_add", "3", "output")
    c.ok(ed.undo() and len(ed.graph.nodes) == 2, "undo reverts the newest step (the graph_add), not the older graph steps")
    c.ok(ed.undo() and ed.undo() and len(ed.curve) == 0 and graph_to_text(ed.graph) == built, "undoing the world move and the curve point leaves the graph as built")
    c.ok(ed.undo() and graph_to_text(ed.graph).find("name=walk") < 0, "the next undo is the graph_set")
    c.ok(ed.redo() and graph_to_text(ed.graph).find("name=walk") >= 0, "redo brings it back")
    cmd(ed, "graph_add", "9", "clip")
    c.ok(not ed.redo(), "a new graph edit ends the redo chain")

    # drag merging
    var before = len(ed.order)
    cmd(ed, "graph_set", "9", "speed", "1.0", "drag")
    cmd(ed, "graph_set", "9", "speed", "1.5", "drag")
    cmd(ed, "graph_set", "9", "speed", "2.0", "drag")
    c.ok(len(ed.order) == before + 1, "three dragged sets of one parameter are one undo step")
    c.ok(ed.undo() and graph_to_text(ed.graph).find("speed") < 0, "one undo removes the whole drag")
    cmd(ed, "graph_set", "9", "speed", "1.0", "drag")
    cmd(ed, "curve_add", "0", "0", "0")
    cmd(ed, "graph_set", "9", "speed", "2.0", "drag")
    c.ok(ed.undo() and ed.undo() and ed.undo() and graph_to_text(ed.graph).find("speed") < 0 and ed.graph.node_index(9) >= 0, "a drag does not merge across an unrelated step: three undos (set, curve, set) undo exactly those, node 9 is still there")

    # failures leave everything alone
    var snap = graph_to_text(ed.graph)
    var n_order = len(ed.order)
    c.ok(fails(ed, "graph_add", "1", "clip") and fails(ed, "graph_connect", "7.out", "1.a") and fails(ed, "graph_remove", "42") and fails(ed, "graph_set", "x", "a", "b") and fails(ed, "graph_disconnect", "1.a") and fails(ed, "graph_connect", "1out", "2.a"), "six bad commands fail")
    c.ok(graph_to_text(ed.graph) == snap and len(ed.order) == n_order, "...and left the graph and the history as they were")

    # remove takes its edges and undoes exactly
    cmd(ed, "graph_remove", "1")
    c.ok(len(ed.graph.edges) == 0 and ed.graph.node_index(1) < 0, "removing node 1 removed its edge")
    c.ok(ed.undo() and graph_to_text(ed.graph) == snap, "undo restores the node and the edge exactly")
    c.ok(empty == "graph graph\n", "(the empty graph is just its header)")

    print("graph_cmd:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("graph_cmd: " + String(c.failed) + " checks failed")
