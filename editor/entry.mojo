"""The two ways into the command layer (ludens-engine #6): a GUI action and the CLI.

Both end in `Registry.run` with text arguments, so the same operation gives the same world either way."""
from editor.ext import Command, CommandSet, Registry
from editor.state import Editor
from geometry.vec import Vec3


def cli_run_in[R: CommandSet](mut ed: Editor, argv: List[String]) raises:
    """`ludens cmd <name> <args...>`: argv[0] is the command name, the rest are its arguments, dispatched in `R`."""
    if len(argv) == 0:
        raise Error("cmd: expected a command name")
    var args = List[String]()
    for i in range(1, len(argv)):
        args.append(argv[i])
    R.run(ed, argv[0], args)


def cli_run[*Cmds: Command](mut ed: Editor, argv: List[String]) raises:
    """cli_run_in over exactly these commands."""
    cli_run_in[Registry[*Cmds]](ed, argv)


def gui_move_body[*Cmds: Command](mut ed: Editor, handle: Int64, pos: Vec3) raises:
    """gui_move_body_in over exactly these commands."""
    gui_move_body_in[Registry[*Cmds]](ed, handle, pos)


def gui_move_body_in[R: CommandSet](mut ed: Editor, handle: Int64, pos: Vec3) raises:
    """What a gizmo drag calls: typed values, formatted to the text the command parser reads."""
    var args = List[String]()
    args.append(String(handle))
    args.append(String(Float64(pos[0])))
    args.append(String(Float64(pos[1])))
    args.append(String(Float64(pos[2])))
    R.run(ed, "move_body", args)
