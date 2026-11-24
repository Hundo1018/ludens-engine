"""The arithmetic of the accessibility post stages (app/access_post.mojo) on the CPU (ludens-engine #118): the reference the GPU
stages are checked against, and the measure the flash limiter is judged by. Standard library only.

Colours are display values in 0 .. 1 (what the frame holds after tone mapping, sRGB-encoded).

Colour-blind filters. The simulation matrices are Machado, Oliveira and Fernandes (2009), severity 1.0, applied to linear RGB.
Each row sums to 1, so a grey stays the same grey (tests/access.mojo checks that). Correction is the classic daltonization
heuristic: what the simulation lost (original minus simulated) is moved into the channels the viewer can use and added back:
protanopia and deuteranopia put the red error into green and blue; tritanopia puts the blue error into red and green. It
makes colours the viewer confuses differ more; it is not a clinical correction. `strength` blends the result with the
unfiltered colour in linear light.

Flash limiter. `flash_limit(prev, cur, step)` returns `cur` when the luminance of `cur` is within `step` of the luminance of
`prev`, and otherwise the colour on the line from `prev` to `cur` whose luminance is exactly `step` away from `prev`'s. Luminance
is 0.2126 R + 0.7152 G + 0.0722 B of the encoded values, so the move along the line is linear in it. The stage keeps `prev` as its own
last output, so a limited frame is the next frame's reference.

`flash_count` measures a series of frame luminances the way the web accessibility guideline words it (a flash is a pair of
opposing changes of at least 10 % of full luminance; more than 3 in any one second fails): it follows the series, starts a
change whenever the series has moved `threshold` away from the last turning point, counts the changes whose direction is
opposite to the one before, and reports the largest number of flashes (two changes make one) inside any window of `fps` frames.
It measures swings between turning points, not single frame steps, so a slow ramp up and down counts and a 1 % wobble does not."""

comptime CB_PROTAN = 1
comptime CB_DEUTAN = 2
comptime CB_TRITAN = 3

comptime Rgb = SIMD[DType.float32, 4]  # r, g, b, and a lane that is carried through unchanged


def srgb_to_linear(c: Float32) -> Float32:
    if c <= 0.04045:
        return c / 12.92
    return Float32(((Float64(c) + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: Float32) -> Float32:
    if c <= 0.0031308:
        return c * 12.92
    return Float32(1.055 * Float64(c) ** (1.0 / 2.4) - 0.055)


def _clamp01(x: Float32) -> Float32:
    return 0.0 if x < 0.0 else (1.0 if x > 1.0 else x)


def cb_matrix(kind: Int) -> List[Float32]:
    """Row-major 3 x 3 simulation matrix (linear RGB) of protanopia, deuteranopia or tritanopia."""
    if kind == CB_PROTAN:
        return [Float32(0.152286), 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998]
    if kind == CB_DEUTAN:
        return [Float32(0.367322), 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881]
    if kind == CB_TRITAN:
        return [Float32(1.255528), -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900]
    return [Float32(1.0), 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]


def simulate_linear(kind: Int, r: Float32, g: Float32, b: Float32) -> Rgb:
    """What a viewer with this kind of colour blindness sees of a linear colour (clamped to 0 .. 1)."""
    var m = cb_matrix(kind)
    return Rgb(
        _clamp01(m[0] * r + m[1] * g + m[2] * b),
        _clamp01(m[3] * r + m[4] * g + m[5] * b),
        _clamp01(m[6] * r + m[7] * g + m[8] * b),
        0.0,
    )


def colorblind_apply(kind: Int, simulate: Bool, strength: Float32, c: Rgb) -> Rgb:
    """The colour-blind stage on one pixel: `c` is an encoded display colour; the result is too."""
    if kind < CB_PROTAN or kind > CB_TRITAN or strength <= 0.0:
        return c
    var r = srgb_to_linear(c[0])
    var g = srgb_to_linear(c[1])
    var b = srgb_to_linear(c[2])
    var s = simulate_linear(kind, r, g, b)
    var out_r = s[0]
    var out_g = s[1]
    var out_b = s[2]
    if not simulate:
        var er = r - s[0]
        var eg = g - s[1]
        var eb = b - s[2]
        if kind == CB_TRITAN:
            out_r = r + er + 0.7 * eb
            out_g = g + eg + 0.7 * eb
            out_b = b
        else:
            out_r = r
            out_g = g + 0.7 * er + eg
            out_b = b + 0.7 * er + eb
    var k = strength if strength < 1.0 else Float32(1.0)
    return Rgb(
        linear_to_srgb(_clamp01(r + (out_r - r) * k)),
        linear_to_srgb(_clamp01(g + (out_g - g) * k)),
        linear_to_srgb(_clamp01(b + (out_b - b) * k)),
        c[3],
    )


def luminance(c: Rgb) -> Float32:
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def flash_limit(prev: Rgb, cur: Rgb, step: Float32) -> Rgb:
    """The flash limiter on one pixel (see the module text). `step` <= 0 means the limiter is off."""
    if step <= 0.0:
        return cur
    var d = luminance(cur) - luminance(prev)
    var a = d if d >= 0.0 else -d
    if a <= step:
        return cur
    var t = step / a
    return prev + (cur - prev) * t


def flash_count(lum: List[Float32], threshold: Float32, fps: Int) -> Int:
    """The largest number of flashes in any window of `fps` consecutive frames of the series (see the module text)."""
    var change_at = List[Int]()  # frame of each change
    var change_up = List[Bool]()
    if len(lum) == 0:
        return 0
    var pivot = lum[0]  # the last turning point: the extreme the series reached before it turned
    var rising = False
    var have_dir = False
    for i in range(1, len(lum)):
        var v = lum[i]
        if not have_dir:
            if v - pivot >= threshold:
                have_dir = True
                rising = True
                pivot = v
                change_at.append(i)
                change_up.append(True)
            elif pivot - v >= threshold:
                have_dir = True
                rising = False
                pivot = v
                change_at.append(i)
                change_up.append(False)
            continue
        if rising:
            if v > pivot:
                pivot = v
            elif pivot - v >= threshold:
                rising = False
                pivot = v
                change_at.append(i)
                change_up.append(False)
        else:
            if v < pivot:
                pivot = v
            elif v - pivot >= threshold:
                rising = True
                pivot = v
                change_at.append(i)
                change_up.append(True)
    # every change after the first reverses the one before it; in a window two changes make one flash
    var best = 0
    for a in range(len(change_at)):
        var n = 0
        for b in range(a, len(change_at)):
            if change_at[b] - change_at[a] >= fps:
                break
            n = b - a + 1
        var f = n // 2
        if f > best:
            best = f
    return best
