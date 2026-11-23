"""The seam between a game and the host that runs it: what a game must provide each frame, as a compile-time trait.

A host (`app/`) is generic over a `GameMode` (`app/main.mojo` `AppOf[M, P]`), so the call to the game is resolved when the
program is built and nothing is looked up at run time. A game conforms by wrapping its state in a struct that implements
these methods; see `game/demo_mode.mojo`. The game's own rules never import this file."""
from game.intent import Intent
from game.draw_item import DrawItem
from procedural.camera_math import CameraPose
from ui.draw import DrawList


trait GameMode(Movable, Deinitable):
    @staticmethod
    def create() raises -> Self:
        """The game at its start; the host calls this when the game is first selected."""
        ...

    def step(mut self, intent: Intent, frame_dt: Float64) raises:
        """Advance by one frame of wall time (the game decides how many fixed ticks that is)."""
        ...

    def scene(mut self) raises -> List[DrawItem]:
        """Everything to draw this frame, in world space."""
        ...

    def camera(self) -> CameraPose:
        ...

    def cues(mut self) -> List[Int]:
        """Sound cues raised since the last call; a game with no sound returns an empty list."""
        ...

    def sounds(self, rate: Int) -> List[List[Float32]]:
        """The game's sound clips as interleaved stereo samples at `rate` Hz; `cues()` numbers them from 1 (clip i is
        cue i + 1). The host registers them once. A game with no sound returns an empty list."""
        ...

    def hud(self, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
        """The 2D overlay in pixels, origin top-left."""
        ...

    def hud_key(self, width: Float32, height: Float32) -> Int64:
        """A version of what `hud` would draw at this size: while it stays the same (and >= 0), the host keeps the
        last HUD instead of calling `hud` and rebuilding its vertices (app/hud.mojo `refresh_hud`). -1 (the default)
        means "unknown, rebuild every frame", so a game that does not override it behaves as before."""
        return -1

    def overlay(mut self, width: Float32, height: Float32, pointer_x: Float32, pointer_y: Float32, pointer_down: Bool, toggle: Bool) raises -> DrawList:
        """A panel the game draws above its HUD and operates with the pointer (the live tuning panel, `game/tuning_panel.mojo`).
        Called every frame with the pointer in canvas pixels, origin top-left; `toggle` is True in the frame the host's
        panel key (F2) went down. An empty list (the default) means no overlay."""
        return DrawList()

    def take_export(mut self) -> String:
        """A file the game wants the host to save, once: the file name, a newline, then its text; empty when there is none
        (the tuning panel's Export button, `game/tuning.mojo`)."""
        return String()

    def physics_ns(self) -> Int64:
        """Nanoseconds the last `step` spent in fixed physics ticks, for the frame breakdown (app/frame_stats.mojo).
        -1 (the default) means the game does not measure it; the host then shows no physics row."""
        return -1

    def hash(self) -> UInt64:
        """A value that changes exactly when the game state changes, for parity checks between targets."""
        ...
