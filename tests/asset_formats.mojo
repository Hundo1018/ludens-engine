"""app/assets.mojo (issue #12) on the synthetic files scripts/test_asset_formats.py writes to build/asset_fixtures/ (run it
through that script, which converts them first).

tiny.lcharacter: two joints, the root under a non-joint parent at y 0.5 (the root transform), the child 1 m above the
root; clip 100 turns the child 90 degrees about z over 31 frames, clip 101 is still. A vertex at (0, 2, 0) bound to the
child goes to root_transform * p = (0, 2.5, 0) at rest and at frame 0, and to (-1, 1.5, 0) at frame 30.
tiny.ltexture: 8 x 8 with levels 8, 4, 2, 1."""
from harness.runner import Suite
from app.assets import parse_character, parse_ltexture, pose_palette_frame, pose_palette_clip, rest_palette


def _read(path: String) raises -> List[UInt8]:
    with open(path, "r") as f:
        return f.read_bytes()


def _apply(pal: List[Float32], joint: Int, x: Float32, y: Float32, z: Float32) -> List[Float32]:
    """The joint's palette matrix (16 floats, column-major) applied to the point (x, y, z, 1)."""
    var out = List[Float32]()
    var o = 16 * joint
    for r in range(3):
        out.append(pal[o + r] * x + pal[o + 4 + r] * y + pal[o + 8 + r] * z + pal[o + 12 + r])
    return out^


def _near(p: List[Float32], x: Float32, y: Float32, z: Float32) -> Bool:
    return abs(p[0] - x) < 1e-5 and abs(p[1] - y) < 1e-5 and abs(p[2] - z) < 1e-5


def main() raises:
    var s = Suite("asset_formats")
    var b = _read("build/asset_fixtures/tiny.lcharacter")
    var c = parse_character(b, 100)
    s.check(len(c.positions) == 12 and len(c.indices) == 6 and c.joint_count == 2, "4 vertices, 6 indices, 2 joints")
    s.check(c.frames == 31 and c.fps == 30 and len(c.motion) == 1, "clip 100 has 31 frames at 30 fps; one motion clip (101)")
    s.check(c.parents[0] == -1 and c.parents[1] == 0, "parents -1, 0")
    s.check(c.joints[8] == 1 and c.weights[8] == 1.0, "vertex 2 is bound to the child with weight 1")

    var rest = rest_palette(c)
    var r = _apply(rest, 1, 0, 2, 0)
    s.check(_near(r, 0, 2.5, 0), "rest: (0, 2, 0) -> root_transform * p = (0, 2.5, 0) (" + String(r[0]) + ", " + String(r[1]) + ")")
    var f0 = _apply(pose_palette_frame(c, 0), 1, 0, 2, 0)
    s.check(_near(f0, 0, 2.5, 0), "frame 0 (child not turned) is the rest pose")
    var f30 = _apply(pose_palette_frame(c, 30), 1, 0, 2, 0)
    s.check(_near(f30, -1, 1.5, 0), "frame 30 (child turned 90 deg about z): (-1, 1.5, 0) (" + String(f30[0]) + ", " + String(f30[1]) + ")")
    var still = _apply(pose_palette_clip(c, c.motion[0], 30), 1, 0, 2, 0)
    s.check(_near(still, 0, 2.5, 0), "the still clip (101) at frame 30 is the rest pose")

    var bad = False
    try:
        _ = pose_palette_frame(c, 31)
    except:
        bad = True
    s.check(bad, "a frame past the clip raises")

    var t = parse_ltexture(_read("build/asset_fixtures/tiny.ltexture"))
    s.check(len(t) == 4 and len(t[0]) == 256 and len(t[1]) == 64 and len(t[2]) == 16 and len(t[3]) == 4,
            "ltexture: 4 levels of 8x8, 4x4, 2x2, 1x1 rgba8")

    var wrong = False
    try:
        _ = parse_ltexture(b)
    except:
        wrong = True
    s.check(wrong, "an .lcharacter is refused as an .ltexture (bad magic)")
    var cut = List[UInt8]()
    for i in range(40):
        cut.append(b[i])
    var short = False
    try:
        _ = parse_character(cut, 100)
    except:
        short = True
    s.check(short, "a truncated .lcharacter raises")
    s.finish()
