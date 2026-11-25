# tier: integration
"""The host side of the accessibility settings (app/access_host.mojo, ludens-engine #118): the player's text scale into the demo
game's HUD, volumes and mono into the mixer, audio events into captions, the shake through the camera. Built with the audio
libraries (scripts/test_audio.py). `pixi run -e wasm test-access`."""
from access_host import AccessHost
from audio_event import AudioEvent, BUS_MUSIC, BUS_SFX
from game.camera_shake import CameraShake
from game.demo_mode import DemoMode
from geometry.vec import Real, Vec3
from mixer import Mixer
from procedural.camera_math import CameraPose, look_rotation
from ui.draw import CMD_TEXT
from ui.scale import UiEnv


struct Check:
    var passed: Int
    var failed: Int

    def __init__(out self):
        self.passed = 0
        self.failed = 0

    def ok(mut self, cond: Bool, label: String):
        if cond:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label)

    def near(mut self, got: Float64, want: Float64, tol: Float64, label: String):
        var d = got - want
        if d < 0.0:
            d = -d
        if d <= tol:
            self.passed += 1
        else:
            self.failed += 1
            print("  [FAIL]", label, "got", got, "want", want, "tol", tol)


def pose(x: Float64, y: Float64, z: Float64) -> CameraPose:
    var v = Vec3(Real(x), Real(y), Real(z), Real(0.0))
    return CameraPose(v, look_rotation(Vec3(Real(0), Real(0), Real(-1), Real(0)), Vec3(Real(0), Real(1), Real(0), Real(0))), 0.9, 1.5, 0.1, 100.0)


def test_host(mut c: Check) raises:
    """The host's wiring (app/access_host.mojo): text scale into the HUD, volumes and mono into the mixer, events into captions."""
    var host = AccessHost()
    var page = UiEnv.default()
    c.near(Float64(host.ui_env(page).text_scale), 1.0, 0.0, "default settings: the page's text scale (1.0) stands")
    var m = DemoMode.create()
    var sizes = List[Float64]()
    var keys = List[Int64]()
    for pct in [100, 150, 200]:
        host.access.set("text_scale", String(pct))
        var env = host.ui_env(page)
        m.set_ui_env(env)
        var dl = m.hud(960, 540, 0.0)
        var first = -1.0
        for i in range(dl.count()):
            if dl.cmds[i].kind == CMD_TEXT:
                first = Float64(dl.cmds[i].value)
                break
        sizes.append(first)
        keys.append(m.hud_key(960, 540))
    print("demo HUD counter font at text scale 100 / 150 / 200 %:", sizes[0], sizes[1], sizes[2], "px")
    c.near(sizes[0], 16.0, 1e-4, "100 %: the counter is 16 px at 960 x 540")
    c.near(sizes[1], 24.0, 1e-4, "150 %: 24 px")
    c.near(sizes[2], 32.0, 1e-4, "200 %: 32 px")
    c.ok(keys[0] != keys[1] and keys[1] != keys[2], "the HUD cache key changes with the text scale, so the host rebuilds the HUD")
    # the page's own value is used while the profile has the default
    host.access.set("text_scale", "100")
    var page2 = UiEnv.default()
    page2.text_scale = 1.25
    c.near(Float64(host.ui_env(page2).text_scale), 1.25, 0.0, "profile at 100 %: the page's 1.25 stands")
    host.access.set("text_scale", "175")
    c.near(Float64(host.ui_env(page2).text_scale), 1.75, 0.0, "profile at 175 %: the profile's value wins")

    # volumes and mono go to the mixer on a step
    var mixer = Mixer(48000, 1)
    host.access.set("volume.music", "30")
    host.access.set("volume.sfx", "60")
    host.access.set("mono", "on")
    host.step(mixer, 1.0 / 60.0)
    c.near(Float64(mixer.user_gain[BUS_MUSIC]), 0.3, 1e-7, "a step sets the mixer's music volume to 0.3")
    c.near(Float64(mixer.user_gain[BUS_SFX]), 0.6, 1e-7, "... sfx to 0.6")
    c.near(Float64(mixer.user_gain[0]), 1.0, 0.0, "... master stays at 1.0")
    c.ok(mixer.mono, "... and mono on")
    host.access.set("mono", "off")
    host.step(mixer, 1.0 / 60.0)
    c.ok(not mixer.mono, "mono off again")

    # an event that starts raises its caption
    _ = mixer.add_clip("cue1", List[Float32](length=200, fill=0.1))
    var ev = AudioEvent("cue1")
    ev.clip_names.append("cue1")
    var id = mixer.add_event(ev^)
    host.captions.load("ludens-captions 1\ncaption cue1 duration=800 text=t\ntext en t Beep\n")
    host.heard(mixer, id)
    c.ok(host.captions.state(True) == '["Beep"]', "heard(event) raises the event's caption: " + host.captions.state(True))
    host.heard(mixer, 99)
    c.ok(host.captions.count() == 1, "an unknown event id raises nothing")
    for _ in range(60):
        host.step(mixer, 1.0 / 60.0)
    c.ok(host.captions.count() == 0, "60 steps of 1/60 s (1000 ms) later the 800 ms caption is gone")
    # the shake goes through the same host
    host.shake.add(1.0)
    var pose_in = pose(0.0, 0.0, 0.0)
    var moved = host.camera(pose_in)
    c.ok(moved.position[0] != pose_in.position[0] or moved.position[1] != pose_in.position[1], "camera(): the shake moves the pose")
    host.access.set("reduce_motion", "on")
    var still = host.camera(pose_in)
    c.ok(still.position[0] == pose_in.position[0] and still.position[1] == pose_in.position[1], "camera(): reduce motion leaves the pose alone")


def main() raises:
    var c = Check()
    test_host(c)
    print("access_app:", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("access_app: " + String(c.failed) + " checks failed")
