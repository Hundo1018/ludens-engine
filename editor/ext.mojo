"""Extension API, first registration point: commands (ludens-shell #18, E13).

A plugin is a Mojo package linked into the same module at build time (the module is statically linked and Mojo
cannot load code at run time). A command is an empty struct that conforms to `Command`; a build lists the commands
it contains as the type parameters of `Registry`, and that list is the registration order:

    comptime Commands = Registry[MoveBody, MyPluginCommand]
    Commands.check()                        # raises, naming both sources, if two commands share a name
    Commands.run(ed, "my_command", args)    # dispatch by name
    Commands.names()                        # for `ludens cmd --list`, in registration order

The registry is a type, so there is no table to fill in at run time and nothing a plugin can reach except the
`Editor` state it is handed. Feasibility is measured in tests/editor_ext.mojo."""
from editor.state import Editor


trait Command(Defaultable, Deinitable):
    @staticmethod
    def name() -> String:
        """The name used on the command line and by the GUI."""
        ...

    @staticmethod
    def source() -> String:
        """The package that registers it; named in a duplicate-name error."""
        ...

    def run(self, mut ed: Editor, args: List[String]) raises:
        """Execute. Errors must leave the world and the undo stack unchanged."""
        ...


struct Registry[*Cmds: Command]:
    @staticmethod
    def names() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.Cmds)):
            out.append(Self.Cmds[i].name())
        return out^

    @staticmethod
    def sources() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.Cmds)):
            out.append(Self.Cmds[i].source())
        return out^

    @staticmethod
    def check() raises:
        """Fail on a repeated name, naming the two registering packages. A build runs this once at start."""
        var names = Self.names()
        var sources = Self.sources()
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                if names[i] == names[j]:
                    raise Error("duplicate command '" + names[i] + "' registered by " + sources[i] + " and " + sources[j])

    @staticmethod
    def run(mut ed: Editor, name: String, args: List[String]) raises:
        comptime for i in range(len(Self.Cmds)):
            if Self.Cmds[i].name() == name:
                Self.Cmds[i]().run(ed, args)
                return
        raise Error("unknown command: " + name)
