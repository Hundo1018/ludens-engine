# tier: unit
"""Accessibility settings (ludens-engine #118): game/access.mojo (ranges, profile rows), game/camera_shake.mojo, game/captions.mojo and
the CPU side of the filters (game/access_filters.mojo): colour-blind matrices against published values and invariants, the
flash limiter against a synthetic flashing scene. Each expected value is worked out from the model in the comment beside it,
not read back from the code under test. `pixi run -e wasm test-access`."""
from game.access import Access, access_rows, join_profile, without_access_rows
from game.access import CB_DEUTAN, CB_PROTAN, CB_TRITAN
from game.access_filters import Rgb, cb_matrix, colorblind_apply, flash_count, flash_limit, linear_to_srgb, luminance, simulate_linear, srgb_to_linear
from game.camera_shake import CameraShake, shake_noise
from game.captions import Captions, MAX_LINES
from geometry.quat import Quat
from geometry.vec import Real, Vec3
from procedural.camera_math import CameraPose, look_rotation
from ui.draw import CMD_FILL, CMD_TEXT, DrawList
from ui.geom import Insets
from ui.scale import UiScale


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


def rejects(mut a: Access, key: String, value: String) -> Bool:
    try:
        a.set(key, value)
        return False
    except:
        return True


def test_ranges(mut c: Check) raises:
    var a = Access()
    c.ok(a.text_scale == 100 and a.shake == 100 and not a.reduce_motion and not a.mono and not a.captions, "defaults: 100 % text, 100 % shake, everything else off")
    a.set("text_scale", "200")
    c.near(Float64(a.text_scale_f()), 2.0, 0.0, "text scale 200 -> 2.0")
    c.ok(rejects(a, "text_scale", "99") and rejects(a, "text_scale", "201"), "text scale outside 100 .. 200 is refused")
    c.ok(a.text_scale == 200, "a refused value leaves the setting as it was")
    c.ok(rejects(a, "shake", "101") and rejects(a, "volume.sfx", "101") and rejects(a, "caption_size", "49") and rejects(a, "flash_step", "0"), "shake, volume, caption size and flash step ranges are enforced")
    c.ok(rejects(a, "colorblind", "blue") and rejects(a, "mono", "yes") and rejects(a, "volume.drums", "50") and rejects(a, "shake", "-5") and rejects(a, "shake", "5x"), "unknown names and malformed numbers are refused")
    a.set("shake", "50")
    c.near(Float64(a.shake_factor()), 0.5, 0.0, "shake 50 % -> 0.5")
    a.set("reduce_motion", "on")
    c.near(Float64(a.shake_factor()), 0.0, 0.0, "reduce motion forces the shake factor to 0")
    a.set("volume.music", "25")
    c.near(Float64(a.volume_gain(1)), 0.25, 0.0, "volume.music 25 -> amplitude 0.25")
    c.near(Float64(a.volume_gain(0)), 1.0, 0.0, "the other buses stay at 1.0")


def test_profile(mut c: Check) raises:
    var a = Access()
    c.ok(a.rows() == "", "defaults write no rows")
    a.set("text_scale", "150")
    a.set("colorblind", "deuteranopia")
    a.set("colorblind_mode", "simulate")
    a.set("volume.voice", "80")
    a.set("mono", "on")
    a.set("captions", "on")
    a.set("caption_background", "0")
    var text = a.rows()
    var want = String("access text_scale 150\naccess colorblind deuteranopia\naccess colorblind_mode simulate\naccess volume.voice 80\naccess mono on\naccess captions on\naccess caption_background 0\n")
    c.ok(text == want, "rows: only what differs, in table order: " + text)
    var b = Access()
    var problems = b.load_rows(text)
    c.ok(len(problems) == 0 and b.rows() == text and b.text_scale == 150 and b.colorblind == CB_DEUTAN and b.volume[5] == 80 and b.mono and b.captions and b.caption_background == 0, "rows read back give the same settings")
    # a profile file holds input rows and access rows; each loader sees only its own
    var file = join_profile(String("ludens-profile 1\nset jump.main key:KeyJ\n"), a)
    c.ok(access_rows(file) == text, "access_rows takes exactly the access rows out of the file")
    c.ok(without_access_rows(file) == "ludens-profile 1\nset jump.main key:KeyJ\n", "without_access_rows leaves the input rows as they were")
    var bad = Access()
    var p = bad.load_rows(String("ludens-profile 1\naccess text_scale 20\naccess shake 40\naccess nonsense 1\naccess mono maybe\n"))
    c.ok(len(p) == 3 and bad.shake == 40 and bad.text_scale == 100, "bad rows are reported (3) and skipped; the good row between them applies")
    c.ok(p[0].startswith("2: text_scale: 20 is outside 100 to 200"), "the message names the line and the range: " + p[0])
    var u = a.post_user(1.0 / 60.0)
    c.ok(u[0] == 2.0 and u[1] == 1.0 and u[2] == 1.0 and u[3] == 0.0, "post_user: deuteranopia, full strength, simulate, limiter off")
    a.set("flash_limit", "on")
    a.set("flash_step", "2")
    c.near(Float64(a.post_user(1.0 / 60.0)[3]), 0.02, 1e-7, "flash step 2 % per 1/60 s -> 0.02 at 60 fps")
    c.near(Float64(a.post_user(1.0 / 120.0)[3]), 0.01, 1e-7, "... 0.01 at 120 fps (the limit per second is the same)")
    c.near(Float64(a.post_user(1.0 / 30.0)[3]), 0.04, 1e-7, "... 0.04 at 30 fps")


def pose(x: Float64, y: Float64, z: Float64) -> CameraPose:
    var v = Vec3(Real(x), Real(y), Real(z), Real(0.0))
    return CameraPose(v, look_rotation(Vec3(Real(0), Real(0), Real(-1), Real(0)), Vec3(Real(0), Real(1), Real(0), Real(0))), 0.9, 1.5, 0.1, 100.0)


def test_shake(mut c: Check) raises:
    var s = CameraShake(7)
    var base = pose(1.0, 2.0, 3.0)
    s.add(0.5)
    s.step(1.0 / 60.0)
    # amplitude = max_offset * trauma^2 * scale; trauma after one step = 0.5 - 1.5 / 60 = 0.475
    var trauma = 0.5 - 1.5 / 60.0
    c.near(Float64(s.trauma), trauma, 1e-6, "trauma falls by decay * dt")
    c.near(Float64(s.amplitude(1.0)), 0.3 * trauma * trauma, 1e-6, "amplitude = 0.3 m * trauma^2")
    var full = s.apply(base, 1.0)
    var half = s.apply(base, 0.5)
    var none = s.apply(base, 0.0)
    var dx_full = Float64(full.position[0] - base.position[0])
    var dy_full = Float64(full.position[1] - base.position[1])
    var dx_half = Float64(half.position[0] - base.position[0])
    var dy_half = Float64(half.position[1] - base.position[1])
    c.ok(abs(dx_full) + abs(dy_full) > 1e-3, "at scale 1 the camera moves")
    c.near(dx_half, dx_full * 0.5, 1e-6, "scale 0.5 moves it half as far in x")
    c.near(dy_half, dy_full * 0.5, 1e-6, "scale 0.5 moves it half as far in y")
    c.ok(none.position[0] == base.position[0] and none.position[1] == base.position[1] and none.position[2] == base.position[2], "scale 0 returns the pose bit for bit")
    c.near(Float64(full.position[2] - base.position[2]), 0.0, 1e-9, "the camera does not move along its view direction")
    c.ok(abs(dx_full) <= 0.3 * trauma * trauma + 1e-9 and abs(dy_full) <= 0.3 * trauma * trauma + 1e-9, "the offset never exceeds the amplitude")
    var a = Access()
    a.set("shake", "100")
    a.set("reduce_motion", "on")
    var moved = s.apply(base, a.shake_factor())
    c.ok(moved.position[0] == base.position[0] and moved.position[1] == base.position[1], "reduce motion: no shake whatever the slider says")
    # determinism: the same seed and frames give the same offsets; a different seed does not
    var s2 = CameraShake(7)
    s2.add(0.5)
    s2.step(1.0 / 60.0)
    c.ok(s2.offset_x(1.0) == s.offset_x(1.0) and s2.offset_y(1.0) == s.offset_y(1.0), "same seed, same frames: same offsets")
    var s3 = CameraShake(8)
    s3.add(0.5)
    s3.step(1.0 / 60.0)
    c.ok(s3.offset_x(1.0) != s.offset_x(1.0), "another seed: other offsets")
    var lo = Float32(1.0)
    var hi = Float32(-1.0)
    for f in range(4000):
        var v = shake_noise(3, UInt64(f), 0)
        lo = min(lo, v)
        hi = max(hi, v)
    c.ok(lo >= -1.0 and hi <= 1.0 and lo < -0.95 and hi > 0.95, "noise covers [-1, 1]: " + String(lo) + " .. " + String(hi))
    for _ in range(100):
        s.step(1.0 / 60.0)
    c.ok(s.trauma == 0.0, "trauma decays to 0 and stays there")
    var rest = s.apply(base, 1.0)
    c.ok(rest.position[0] == base.position[0], "no trauma: no movement")


# ---- colour-blind filters -----------------------------------------------------------------------------------------------

def test_colorblind(mut c: Check) raises:
    # Machado et al. 2009, severity 1.0, protanopia, applied to linear (1, 0, 0): the first column of the published matrix.
    var red = simulate_linear(CB_PROTAN, 1.0, 0.0, 0.0)
    c.near(Float64(red[0]), 0.152286, 1e-6, "protanopia of linear red: R = 0.152286 (published first column)")
    c.near(Float64(red[1]), 0.114503, 1e-6, "protanopia of linear red: G = 0.114503")
    c.near(Float64(red[2]), 0.0, 1e-6, "protanopia of linear red: B = -0.003882 clamps to 0")
    var green = simulate_linear(CB_DEUTAN, 0.0, 1.0, 0.0)
    c.near(Float64(green[0]), 0.860646, 1e-6, "deuteranopia of linear green: R = 0.860646 (second column)")
    c.near(Float64(green[1]), 0.672501, 1e-6, "deuteranopia of linear green: G = 0.672501")
    var blue = simulate_linear(CB_TRITAN, 0.0, 0.0, 1.0)
    c.near(Float64(blue[1]), 0.147602, 1e-6, "tritanopia of linear blue: G = 0.147602 (third column)")
    c.near(Float64(blue[2]), 0.3039, 1e-6, "tritanopia of linear blue: B = 0.303900")
    # invariant: each row sums to 1, so white and every grey are unchanged
    for k in range(1, 4):
        var m = cb_matrix(k)
        for r in range(3):
            c.near(Float64(m[3 * r] + m[3 * r + 1] + m[3 * r + 2]), 1.0, 2e-6, "matrix " + String(k) + " row " + String(r) + " sums to 1")
        for g in [Float32(0.0), 0.2, 0.5, 0.8, 1.0]:
            var out = colorblind_apply(k, True, 1.0, Rgb(g, g, g, 1.0))
            c.near(Float64(out[0]), Float64(g), 2e-4, "grey " + String(g) + " is a grey in simulation " + String(k))
            c.near(Float64(out[1]), Float64(g), 2e-4, "grey " + String(g) + " (G) in simulation " + String(k))
            c.near(Float64(out[2]), Float64(g), 2e-4, "grey " + String(g) + " (B) in simulation " + String(k))
    # off, and strength 0, change nothing; strength 0.5 is halfway in linear light
    var px = Rgb(0.8, 0.3, 0.1, 1.0)
    var same = colorblind_apply(0, True, 1.0, px)
    c.ok(same[0] == px[0] and same[1] == px[1] and same[2] == px[2], "kind off returns the colour")
    var zero = colorblind_apply(CB_PROTAN, True, 0.0, px)
    c.ok(zero[0] == px[0] and zero[1] == px[1] and zero[2] == px[2], "strength 0 returns the colour")
    var full = colorblind_apply(CB_PROTAN, True, 1.0, px)
    var half = colorblind_apply(CB_PROTAN, True, 0.5, px)
    var lin0 = srgb_to_linear(px[0])
    var lin1 = srgb_to_linear(full[0])
    c.near(Float64(srgb_to_linear(half[0])), Float64(lin0 + lin1) / 2.0, 1e-4, "strength 0.5 is halfway in linear light")
    c.near(Float64(linear_to_srgb(srgb_to_linear(0.37))), 0.37, 1e-5, "sRGB round trip")
    c.near(Float64(srgb_to_linear(0.5)), 0.21404114, 1e-6, "sRGB 0.5 is 0.214041 in linear light (IEC 61966-2-1)")
    # correction does what it is for: two colours a protanope confuses end up further apart in what that viewer sees.
    # A dark-ish red and a green of about the same luminance (the pair a protanope cannot separate).
    var a = Rgb(0.60, 0.30, 0.20, 1.0)
    var b = Rgb(0.35, 0.50, 0.20, 1.0)
    var before = _distance(colorblind_apply(CB_PROTAN, True, 1.0, a), colorblind_apply(CB_PROTAN, True, 1.0, b))
    var ca = colorblind_apply(CB_PROTAN, False, 1.0, a)
    var cb = colorblind_apply(CB_PROTAN, False, 1.0, b)
    var after = _distance(colorblind_apply(CB_PROTAN, True, 1.0, ca), colorblind_apply(CB_PROTAN, True, 1.0, cb))
    print("protanope distance between a red and a green: uncorrected", before, "corrected", after)
    c.ok(after > before * 1.2, "protanopia correction: the confusable pair is at least 1.2x further apart in simulation (" + String(before) + " -> " + String(after) + ")")
    var da = Rgb(0.60, 0.30, 0.20, 1.0)
    var db = Rgb(0.35, 0.50, 0.20, 1.0)
    var d_before = _distance(colorblind_apply(CB_DEUTAN, True, 1.0, da), colorblind_apply(CB_DEUTAN, True, 1.0, db))
    var d_after = _distance(
        colorblind_apply(CB_DEUTAN, True, 1.0, colorblind_apply(CB_DEUTAN, False, 1.0, da)),
        colorblind_apply(CB_DEUTAN, True, 1.0, colorblind_apply(CB_DEUTAN, False, 1.0, db)),
    )
    print("deuteranope distance:", d_before, "->", d_after)
    c.ok(d_after > d_before * 1.2, "deuteranopia correction: the pair is at least 1.2x further apart (" + String(d_before) + " -> " + String(d_after) + ")")
    # tritan: a blue and a green
    var ta = Rgb(0.20, 0.45, 0.65, 1.0)
    var tb = Rgb(0.20, 0.60, 0.55, 1.0)
    var t_before = _distance(colorblind_apply(CB_TRITAN, True, 1.0, ta), colorblind_apply(CB_TRITAN, True, 1.0, tb))
    var t_after = _distance(
        colorblind_apply(CB_TRITAN, True, 1.0, colorblind_apply(CB_TRITAN, False, 1.0, ta)),
        colorblind_apply(CB_TRITAN, True, 1.0, colorblind_apply(CB_TRITAN, False, 1.0, tb)),
    )
    print("tritanope distance:", t_before, "->", t_after)
    c.ok(t_after > t_before * 1.2, "tritanopia correction: the pair is at least 1.2x further apart (" + String(t_before) + " -> " + String(t_after) + ")")
    # worked value: protanopia correction of pure red. Linear (1, 0, 0): simulated = (0.152286, 0.114503, -0.003882 -> 0);
    # error = (0.847714, -0.114503, 0); corrected G = 0 + 0.7 * 0.847714 + (-0.114503) = 0.478896, B = 0 + 0.7 * 0.847714 = 0.593400
    var red_fixed = colorblind_apply(CB_PROTAN, False, 1.0, Rgb(1.0, 0.0, 0.0, 1.0))
    c.near(Float64(red_fixed[0]), 1.0, 1e-5, "protanopia correction of red: R stays 1")
    c.near(Float64(red_fixed[1]), Float64(linear_to_srgb(0.478896)), 2e-4, "protanopia correction of red: G = encode(0.478896)")
    c.near(Float64(red_fixed[2]), Float64(linear_to_srgb(0.5934)), 2e-4, "protanopia correction of red: B = encode(0.593400)")
    # a colour the viewer already sees right (a grey) is not changed by correction
    var gray = colorblind_apply(CB_PROTAN, False, 1.0, Rgb(0.5, 0.5, 0.5, 1.0))
    c.near(Float64(gray[0]), 0.5, 2e-4, "correction leaves a grey alone")


def _distance(a: Rgb, b: Rgb) -> Float64:
    var dr = Float64(a[0] - b[0])
    var dg = Float64(a[1] - b[1])
    var db = Float64(a[2] - b[2])
    return (dr * dr + dg * dg + db * db) ** 0.5


# ---- the flash limiter on a synthetic flashing scene ----------------------------------------------------------------

def flashing_scene(frames: Int, half_period: Int) -> List[Float32]:
    """Mean luminance of a full-screen scene that is white for `half_period` frames, then black for `half_period` frames."""
    var out = List[Float32]()
    for i in range(frames):
        out.append(1.0 if (i // half_period) % 2 == 0 else Float32(0.0))
    return out^


def limited(series: List[Float32], step: Float32) -> List[Float32]:
    """The same scene through the limiter, one grey pixel, the first frame passed through."""
    var out = List[Float32]()
    var prev = Rgb(series[0], series[0], series[0], 1.0)
    out.append(series[0])
    for i in range(1, len(series)):
        var cur = Rgb(series[i], series[i], series[i], 1.0)
        prev = flash_limit(prev, cur, step)
        out.append(luminance(prev))
    return out^


def max_step(series: List[Float32]) -> Float32:
    var m = Float32(0.0)
    for i in range(1, len(series)):
        var d = series[i] - series[i - 1]
        m = max(m, d if d >= 0.0 else -d)
    return m


def test_flash(mut c: Check) raises:
    # the counter on hand-made series
    var steady = List[Float32]()
    for _ in range(120):
        steady.append(0.5)
    c.ok(flash_count(steady, 0.1, 60) == 0, "a steady frame has no flashes")
    c.ok(flash_count(flashing_scene(120, 3), 0.1, 60) == 10, "white 3 frames / black 3 frames at 60 fps: 10 flashes a second")
    c.ok(flash_count(flashing_scene(120, 6), 0.1, 60) == 5, "6 / 6: 5 flashes a second")
    c.ok(flash_count(flashing_scene(120, 10), 0.1, 60) == 3, "10 / 10: 3 flashes a second (the allowed limit)")
    c.ok(flash_count(flashing_scene(120, 30), 0.1, 60) == 1, "30 / 30: 1 flash a second")
    # a reversal on the very frame after the first change: two changes make one flash
    c.ok(flash_count([Float32(0.0), 1.0, 0.0], 0.1, 60) == 1, "0, 1, 0: two opposing changes are 1 flash")
    c.ok(flash_count([Float32(1.0), 0.0, 1.0], 0.1, 60) == 1, "1, 0, 1: 1 flash")
    c.ok(flash_count([Float32(0.0), 1.0, 0.0, 1.0], 0.1, 60) == 1, "0, 1, 0, 1: three changes are 1 flash")
    c.ok(flash_count([Float32(0.0), 1.0, 0.0, 1.0, 0.0], 0.1, 60) == 2, "0, 1, 0, 1, 0: four changes are 2 flashes")
    c.ok(flash_count(flashing_scene(120, 1), 0.1, 60) == 30, "1 frame on / 1 frame off at 60 fps: 30 flashes a second (the most the frame rate allows)")
    c.ok(flash_count([Float32(0.0), 1.0], 0.1, 60) == 0, "one change alone is no flash")
    var wobble = List[Float32]()
    for i in range(120):
        wobble.append(0.5 + (0.04 if i % 2 == 0 else Float32(-0.04)))
    c.ok(flash_count(wobble, 0.1, 60) == 0, "a +-4 % wobble every frame is under the 10 % threshold: 0 flashes")
    # the limiter at 1 % per 1/60 s, on scenes that flash more than 3 times a second
    var step = Float32(0.01)
    for half in [1, 2, 3, 4, 6]:
        var scene = flashing_scene(240, half)
        var raw = flash_count(scene, 0.1, 60)
        var out = limited(scene, step)
        var after = flash_count(out, 0.1, 60)
        print("half period", half, "frames:", raw, "flashes a second ->", after, ", largest frame step", max_step(scene), "->", max_step(out))
        c.ok(raw > 3, "the scene with half period " + String(half) + " fails the 3 a second rule (" + String(raw) + ")")
        c.ok(after <= 3, "after the limiter, half period " + String(half) + ": " + String(after) + " flashes a second, at most 3")
        c.ok(max_step(out) <= step + 1e-6, "no frame moves the luminance by more than the step (" + String(max_step(out)) + ")")
    # a slow scene is not changed: a 2 s half period only has 0.25 flashes a second, and its single cut is limited to a ramp
    var slow = limited(flashing_scene(240, 120), step)
    c.ok(slow[0] == 1.0 and slow[119] == 1.0, "while the scene holds a level the limiter holds it")
    # after the cut to black at frame 120 the luminance falls 0.01 a frame: 100 frames to reach 0
    c.near(Float64(slow[120]), 0.99, 1e-5, "the cut to black: first frame 0.99")
    c.near(Float64(slow[219]), 0.0, 1e-5, "... reaches 0 at frame 219 (100 frames of 1 %)")
    # off, and an unchanged pixel
    var a = Rgb(0.9, 0.9, 0.9, 1.0)
    var b = Rgb(0.1, 0.1, 0.1, 1.0)
    var off = flash_limit(a, b, 0.0)
    c.ok(off[0] == 0.1, "step 0: the limiter is off")
    var inside = flash_limit(a, Rgb(0.895, 0.895, 0.895, 1.0), 0.01)
    c.ok(inside[0] == 0.895, "a change inside the step passes unchanged")
    # a coloured pixel moves along the line to the new colour; its luminance moves exactly `step`
    var r = flash_limit(Rgb(0.0, 0.0, 0.0, 1.0), Rgb(1.0, 0.0, 0.0, 1.0), 0.1)
    c.near(Float64(luminance(r)), 0.1, 1e-6, "red from black with step 0.1: luminance 0.1")
    c.near(Float64(r[0]), 0.1 / 0.2126, 1e-5, "... on the line to red: R = 0.1 / 0.2126")
    c.ok(r[1] == 0.0 and r[2] == 0.0, "... G and B stay 0")


# ---- captions --------------------------------------------------------------------------------------------------------------

comptime TRACK = """ludens-captions 1
# the sounds of the demo game
caption cue1 duration=1200 speaker=who.ball text=cap.jump
caption cue2 duration=900 text=cap.impact
text en who.ball Ball
text en cap.jump jumps
text en cap.impact Something lands # not part of the string
text zh-TW who.ball 球
text zh-TW cap.jump 跳起來
"""


def count_cmds(dl: DrawList, kind: Int) -> Int:
    var n = 0
    for i in range(dl.count()):
        if dl.cmds[i].kind == kind:
            n += 1
    return n


def test_captions(mut c: Check) raises:
    var cap = Captions()
    cap.load(TRACK)
    c.ok(len(cap.rows) == 2 and len(cap.locales) == 2, "the track has 2 rows and 2 locales")
    c.ok(cap.trigger("cue1") and not cap.trigger("nothing"), "an event with a row shows; one without does not")
    c.ok(cap.state(True) == '["Ball: jumps"]', "speaker name and text: " + cap.state(True))
    c.ok(cap.state(False) == '["jumps"]', "speaker names off: " + cap.state(False))
    _ = cap.trigger("cue2")
    c.ok(cap.state(True) == '["Ball: jumps","Something lands"]', "a caption with no speaker; the # comment is not in the text: " + cap.state(True))
    cap.update(800.0)
    c.ok(cap.count() == 2, "at 800 ms both are up (the rows last 1200 and 900 ms)")
    cap.update(150.0)
    c.ok(cap.state(True) == '["Ball: jumps"]', "at 950 ms the 900 ms caption is gone: " + cap.state(True))
    cap.update(300.0)
    c.ok(cap.count() == 0, "at 1250 ms the 1200 ms one is gone")
    # a repeating sound restarts its timer instead of stacking
    _ = cap.trigger("cue1")
    cap.update(1000.0)
    _ = cap.trigger("cue1")
    c.ok(cap.count() == 1, "cue1 raised twice is one caption, not two")
    cap.update(1000.0)
    c.ok(cap.count() == 1, "its timer was restarted: 1000 ms after the second raise (1200 ms row) it is still up")
    # at most MAX_LINES
    cap.clear()
    for i in range(5):
        cap.say("Mara", "line " + String(i), 5000)
    c.ok(cap.count() == MAX_LINES and cap.state(True) == '["Mara: line 2","Mara: line 3","Mara: line 4"]', "dialogue: the oldest of 5 lines are dropped, " + String(MAX_LINES) + " stay: " + cap.state(True))
    # locale
    cap.clear()
    c.ok(cap.set_locale("zh-TW") and cap.trigger("cue1"), "zh-TW selected")
    c.ok(cap.state(True) == '["球: 跳起來"]', "the caption follows the locale: " + cap.state(True))
    cap.clear()
    _ = cap.trigger("cue2")
    c.ok(cap.state(True) == '["Something lands"]', "a key missing in zh-TW falls back to the first locale of the file: " + cap.state(True))
    cap.set_locale_index(0)
    cap.clear()
    # errors
    var raised = False
    try:
        cap.load("ludens-captions 1\ncaption cue1 duration=50 text=x\n")
    except e:
        raised = String(e).startswith("2: duration must be")
    c.ok(raised, "a duration under 100 ms is refused with its line number")
    raised = False
    try:
        cap.load("caption cue1 duration=500 text=x\n")
    except e:
        raised = String(e).startswith("1: expected `ludens-captions 1`")
    c.ok(raised, "a track without its header is refused")
    c.ok(len(cap.rows) == 2, "a refused load leaves the old rows")

    # drawing
    var a = Access()
    var ui = UiScale.reference(960, 540)
    var dl = DrawList()
    cap.say("Mara", "Over here!", 5000)
    cap.draw(dl, 960, 540, ui, None, a)
    c.ok(dl.count() == 0, "captions off: nothing is drawn")
    a.set("captions", "on")
    cap.draw(dl, 960, 540, ui, None, a)
    c.ok(count_cmds(dl, CMD_TEXT) == 1 and count_cmds(dl, CMD_FILL) == 1, "captions on: one box and one text")
    c.ok(dl.cmds[1].text == "Mara: Over here!", "the text is `Mara: Over here!`")
    c.near(Float64(dl.cmds[0].color.a), 0.75, 0.0, "the default background is 75 % opaque")
    var size100 = Float64(dl.cmds[1].value)
    c.near(size100, 18.0, 1e-4, "the text is 18 px at 960 x 540, 100 % size, 100 % text scale")
    # the box contains its text
    var box = dl.cmds[0].rect
    var txt = dl.cmds[1].rect
    c.ok(box.x <= txt.x and box.y <= txt.y and box.right() >= txt.x + txt.w * 0.98 and box.bottom() >= txt.bottom(), "the box holds the text")
    c.ok(box.bottom() <= 540.0, "the box is inside the window")
    # size and background options
    a.set("caption_size", "150")
    var dl2 = DrawList()
    cap.draw(dl2, 960, 540, ui, None, a)
    c.near(Float64(dl2.cmds[1].value), 27.0, 1e-4, "caption size 150 % -> 27 px")
    a.set("caption_size", "100")
    ui.set_text_scale(2.0)
    var dl3 = DrawList()
    cap.draw(dl3, 960, 540, ui, None, a)
    c.near(Float64(dl3.cmds[1].value), 36.0, 1e-4, "UI text scale 200 % -> 36 px")
    ui.set_text_scale(1.0)
    a.set("caption_background", "0")
    var dl4 = DrawList()
    cap.draw(dl4, 960, 540, ui, None, a)
    c.ok(count_cmds(dl4, CMD_FILL) == 0 and count_cmds(dl4, CMD_TEXT) == 1, "background 0: no box, the text stays")
    a.set("caption_background", "40")
    var dl5 = DrawList()
    cap.draw(dl5, 960, 540, ui, None, a)
    c.near(Float64(dl5.cmds[0].color.a), 0.4, 1e-6, "background 40 % -> alpha 0.4")
    a.set("caption_speaker", "off")
    var dl6 = DrawList()
    cap.draw(dl6, 960, 540, ui, None, a)
    c.ok(dl6.cmds[1].text == "Over here!", "speaker off: `Over here!`")
    a.set("caption_speaker", "on")
    # the safe area: the boxes stay inside it, also at 200 % x 200 % with a long line
    ui.insets = Insets(40, 20, 40, 30)
    ui.set_text_scale(2.0)
    a.set("caption_size", "200")
    cap.clear()
    cap.say("Narrator", "This is a long line of dialogue that has to wrap inside the safe area of a small window", 5000)
    cap.say("Mara", "Short", 5000)
    var dl7 = DrawList()
    cap.draw(dl7, 640, 360, ui, None, a)
    var safe = ui.safe_rect(640, 360)
    var inside = True
    for i in range(dl7.count()):
        if dl7.cmds[i].kind == CMD_FILL:
            var r = dl7.cmds[i].rect
            if r.x < safe.x - 0.01 or r.right() > safe.right() + 0.01 or r.bottom() > safe.bottom() + 0.01:
                inside = False
    c.ok(inside, "at 200 % x 200 % in a 640 x 360 window with insets, every box is inside the safe rectangle")
    # the newest line is the lowest
    c.ok(dl7.cmds[1].text.startswith("Mara") or dl7.cmds[3].text.startswith("Mara"), "the newest line is drawn")


def main() raises:
    var c = Check()
    test_ranges(c)
    test_profile(c)
    test_shake(c)
    test_colorblind(c)
    test_flash(c)
    test_captions(c)
    print("access: ", c.passed, "/", c.passed + c.failed, "checks")
    if c.failed > 0:
        raise Error("access: " + String(c.failed) + " checks failed")
