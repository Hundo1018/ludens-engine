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
from ui.geom import Rect
from ui.immediate import Ui


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
        """Execute. Errors must leave the world unchanged (use `ed.begin` / `touch` / `commit`: an open transaction is aborted when the command raises)."""
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
                try:
                    Self.Cmds[i]().run(ed, args)
                except e:
                    ed.abort()  # a transaction the command left open is rolled back
                    raise e^
                return
        raise Error("unknown command: " + name)


# ---- panels -------------------------------------------------------------------------------------------------------

comptime DOCK_LEFT = 0
comptime DOCK_RIGHT = 1
comptime DOCK_BOTTOM = 2
comptime DOCK_CENTER = 3


trait Panel(Defaultable, Deinitable):
    @staticmethod
    def name() -> String: ...

    @staticmethod
    def dock() -> Int:
        """Default dock position (`DOCK_*`)."""
        ...

    def draw(self, mut ui: Ui, area: Rect, mut ed: Editor) raises:
        """Draw into `ui` inside `area` with `ui/` widgets. Edits go through `Registry.run`, not around it."""
        ...


struct PanelRegistry[*Ps: Panel]:
    @staticmethod
    def names() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.Ps)):
            out.append(Self.Ps[i].name())
        return out^

    @staticmethod
    def docks() -> List[Int]:
        var out = List[Int]()
        comptime for i in range(len(Self.Ps)):
            out.append(Self.Ps[i].dock())
        return out^

    @staticmethod
    def check() raises:
        var names = Self.names()
        for i in range(len(names)):
            for j in range(i + 1, len(names)):
                if names[i] == names[j]:
                    raise Error("duplicate panel '" + names[i] + "' (registrations " + String(i) + " and " + String(j) + ")")

    @staticmethod
    def draw_all(mut ui: Ui, areas: List[Rect], mut ed: Editor) raises:
        """Draw every panel, in registration order, into the matching entry of `areas`."""
        comptime for i in range(len(Self.Ps)):
            Self.Ps[i]().draw(ui, areas[i], ed)


# ---- type drawers -------------------------------------------------------------------------------------------------


trait TypeDrawer(Defaultable, Deinitable):
    @staticmethod
    def type_name() -> String:
        """The 17.11 `TypeSchema` type name this drawer shows and edits."""
        ...

    def draw(self, mut ui: Ui, area: Rect, value: String) raises -> String:
        """Show `value` (text form) and return the text after editing; equal to `value` when unchanged."""
        ...


struct DrawerRegistry[*Ds: TypeDrawer]:
    @staticmethod
    def type_names() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.Ds)):
            out.append(Self.Ds[i].type_name())
        return out^

    @staticmethod
    def has(type_name: String) -> Bool:
        comptime for i in range(len(Self.Ds)):
            if Self.Ds[i].type_name() == type_name:
                return True
        return False

    @staticmethod
    def draw(type_name: String, mut ui: Ui, area: Rect, value: String) raises -> String:
        comptime for i in range(len(Self.Ds)):
            if Self.Ds[i].type_name() == type_name:
                return Self.Ds[i]().draw(ui, area, value)
        raise Error("no drawer for type " + type_name)


# ---- asset importers ----------------------------------------------------------------------------------------------


trait Importer(Defaultable, Deinitable):
    @staticmethod
    def extension() -> String:
        """File extension without the dot, lower case."""
        ...

    def import_file(self, data: List[UInt8]) raises -> List[UInt8]:
        """Turn source bytes into the bytes stored in the asset library (#12)."""
        ...


struct ImporterRegistry[*Is: Importer]:
    @staticmethod
    def extensions() -> List[String]:
        var out = List[String]()
        comptime for i in range(len(Self.Is)):
            out.append(Self.Is[i].extension())
        return out^

    @staticmethod
    def check() raises:
        var e = Self.extensions()
        for i in range(len(e)):
            for j in range(i + 1, len(e)):
                if e[i] == e[j]:
                    raise Error("duplicate importer for ." + e[i])

    @staticmethod
    def import_file(path: String, data: List[UInt8]) raises -> List[UInt8]:
        var ext = String()
        var parts = path.split(".")
        if len(parts) > 1:
            ext = String(parts[len(parts) - 1]).lower()
        comptime for i in range(len(Self.Is)):
            if Self.Is[i].extension() == ext:
                return Self.Is[i]().import_file(data)
        raise Error("no importer for ." + ext)
