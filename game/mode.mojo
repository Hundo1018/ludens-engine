"""The seam between a game and the host that runs it: what a game must provide each frame, as a compile-time trait.

A host (`app/`) is generic over a `GameMode` (`app/main.mojo` `AppOf[M, P]`), so the call to the game is resolved when the
program is built and nothing is looked up at run time. A game conforms by wrapping its state in a struct that implements
these methods; see `game/demo_mode.mojo`. The game's own rules never import this file."""
from game.intent import Intent
from game.draw_item import DrawItem
from procedural.camera_math import CameraPose
from ui.draw import DrawList
from ui.scale import UiEnv
from ui.sdf_font import FontMetrics


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

    def set_ui_env(mut self, env: UiEnv):
        """The host's safe-area insets, text scale, locale index and pseudo-localization flag (ui/scale.mojo `UiEnv`),
        called every frame before `hud_key`. A game that lays out its HUD from them folds `env.key()` into its `hud_key`.
        The default ignores them."""
        pass

    def set_font_metrics(mut self, metrics: FontMetrics):
        """The glyph advances of the font the host draws text with (ui/sdf_font.mojo), once when it has loaded one: a game
        that sizes panels around its text measures with it. The default ignores them."""
        pass

    def hud_key(self, width: Float32, height: Float32) -> Int64:
        """A version of what `hud` would draw at this size: while it stays the same (and >= 0), the host keeps the
        last HUD instead of calling `hud` and rebuilding its vertices (app/hud.mojo `refresh_hud`). -1 (the default)
        means "unknown, rebuild every frame", so a game that does not override it behaves as before."""
        return -1

    def physics_ns(self) -> Int64:
        """Nanoseconds the last `step` spent in fixed physics ticks, for the frame breakdown (app/frame_stats.mojo).
        -1 (the default) means the game does not measure it; the host then shows no physics row."""
        return -1

    def hash(self) -> UInt64:
        """A value that changes exactly when the game state changes, for parity checks between targets."""
        ...

    def state(self) -> String:
        """The game's state as one JSON object, for a test or an agent to read (`window.game.state()`, docs/automation.md).
        Numbers are written the way `String(Float64)` prints them, so two runs with the same state give the same text.
        The default is the hash alone; a game overrides it with the fields a script needs, e.g. positions and counters."""
        return String('{"hash":"') + String(self.hash()) + String('"}')

    def reset(mut self, seed: UInt64, scene: String) raises -> Bool:
        """Start over in the named scene ("" = the game's default) with the given seed (0 = the game's fixed layout);
        the host calls it for `?seed=` / `?scene=`, the batch runner once per seed. Raise for an unknown scene. False
        (the default) means the game has no seeds or scenes: the host then reports it instead of ignoring the request."""
        return False
