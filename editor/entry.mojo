"""The two ways into the command layer (ludens-shell #6): a GUI action and the CLI.

Both end in `Editor.execute` with text arguments, so the same operation gives the same world either way."""
from editor.command import Editor
from geometry.vec import Vec3


def cli_run(mut ed: Editor, argv: List[String]) raises:
    """`ludens cmd <name> <args...>`: argv[0] is the command name, the rest are its arguments."""
    if len(argv) == 0:
        raise Error("cmd: expected a command name")
    var args = List[String]()
    for i in range(1, len(argv)):
        args.append(argv[i])
    ed.execute(argv[0], args)


def gui_move_body(mut ed: Editor, handle: Int64, pos: Vec3) raises:
    """What a gizmo drag calls: typed values, formatted to the text the command parser reads."""
    var args = List[String]()
    args.append(String(handle))
    args.append(String(Float64(pos[0])))
    args.append(String(Float64(pos[1])))
    args.append(String(Float64(pos[2])))
    ed.execute("move_body", args)
