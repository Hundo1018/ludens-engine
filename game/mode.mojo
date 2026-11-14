"""The seam between a game and the host that runs it: what a game must provide each frame, as a compile-time trait.

A host (`app/`) is generic over a `GameMode` (`struct Host[M: GameMode]`), so the call to the game is resolved when the
program is built and nothing is looked up at run time. A game conforms by wrapping its state in a struct that implements
these methods; see `game/arena_mode.mojo`. The game's own rules never import this file."""
from game.intent import Intent
from game.arena import DrawItem
from procedural.camera_math import CameraPose
from ui.draw import DrawList


trait GameMode(Movable, Deinitable):
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

    def hud(self, width: Float32, height: Float32, frame_ms: Float32) raises -> DrawList:
        """The 2D overlay in pixels, origin top-left."""
        ...

    def hash(self) -> UInt64:
        """A value that changes exactly when the game state changes, for parity checks between targets."""
        ...
