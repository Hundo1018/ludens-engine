"""The host's side of the accessibility settings (ludens-engine #118): the player's `Access`, the caption queue and the camera shake,
and the few lines that carry them to the mixer, the renderer and the HUD. `AppOf` (app/main.mojo) owns one and calls it at five
places: once per game frame (`step`), when the mixer starts an event (`heard`), when the view is made (`camera`), when the scene
renderer is configured (`renderer`) and when the HUD is built (`captions_into`). The settings live in the profile file
(app/profile.mojo); the page changes them with `app_access_set`."""
from audio_event import BUS_COUNT
from game.access import Access
from game.camera_shake import CameraShake
from game.captions import Captions
from mixer import Mixer
from procedural.camera_math import CameraPose
from ui.draw import DrawList
from ui.scale import UiEnv, UiScale
from ui.sdf_font import FontMetrics


struct AccessHost(Movable):
    var access: Access
    var captions: Captions
    var shake: CameraShake
    var frame_dt: Float32  # the latest game frame's duration in seconds, for the flash limiter's step

    def __init__(out self):
        self.access = Access()
        self.captions = Captions()
        self.shake = CameraShake()
        self.frame_dt = Float32(1.0 / 60.0)

    def step(mut self, mut mixer: Mixer, dt: Float64):
        """One game frame: the player's volumes and mono go to the mixer, captions age, the shake decays."""
        self.frame_dt = Float32(dt)
        for b in range(BUS_COUNT):
            mixer.set_user_volume(b, self.access.volume_gain(b))
        mixer.set_mono(self.access.mono)
        self.captions.update(Float32(dt * 1000.0))
        self.shake.step(Float32(dt))

    def heard(mut self, mixer: Mixer, event: Int):
        """The mixer started this event: raise its caption, if the track has one."""
        if event >= 0 and event < len(mixer.events):
            _ = self.captions.trigger(mixer.events[event].name)

    def camera(self, pose: CameraPose) -> CameraPose:
        """The pose the view is made from: the game's camera plus the shake at the player's scale."""
        return self.shake.apply(pose, self.access.shake_factor())

    def ui_env(mut self, env: UiEnv) -> UiEnv:
        """The page's UI settings with the player's text scale: the profile's value when it is not the default 100 %, else the page's."""
        var out = env
        if self.access.text_scale != 100:
            out.text_scale = self.access.text_scale_f()
        self.captions.set_locale_index(env.locale)
        return out

    def captions_into(self, mut dl: DrawList, width: Float32, height: Float32, env: UiEnv, metrics: Optional[FontMetrics]):
        var ui = UiScale.reference(960, 540)
        ui.insets = env.insets
        ui.set_text_scale(env.text_scale)
        self.captions.draw(dl, width, height, ui, metrics, self.access)
