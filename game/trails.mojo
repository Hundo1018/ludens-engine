"""Trails and ribbons on the CPU (#140): a strip of points left behind a moving thing (a weapon swing, a tyre mark, a
missile), each point with a width and a colour that follow its age. The GPU side is `app/trail_pass.mojo`.

A trail is fed the position of what it follows (`move_to(time, x, y, z)`): a point is added when the position is at
least `min_step` metres from the last point, so the spacing does not depend on the frame rate. `expire(time)` removes the
points older than `lifetime` from the tail. Over `max_points` the oldest point is dropped and counted (`dropped`).

Age t = (time - birth) / lifetime in [0, 1]: width = curve_at(width_curve, t), colour = color3(start, mid, end, t), the
same two functions the particle records use (game/particles.mojo), so a trail and a particle of the same age and table
values have the same size and colour.

`TrailSystem.pack` writes one record per segment (two consecutive points of a trail), 6 vec4: [pA, wA] [colour A]
[tangent A, flat] [pB, wB] [colour B] [tangent B, flat]. The tangent at a point is the direction from the previous point to
the next (one-sided at the ends), so two segments that meet at a point turn the strip's edge by the same vector and
the strip has no gap at the joint. Alpha-blended segments of all trails are sorted far to near along the camera's
forward axis (particles' `merge_order`, ties by index), additive ones follow in trail order.

Determinism: + - * / and sqrt on Float64 only; the same calls give the same bytes (`app/tier2_parity.mojo` compares
native and wasm64)."""
from std.math import sqrt
from game.particles import curve_at, color3, merge_order

comptime TRAIL_SEGMENT_FLOATS = 24
comptime TRAIL_BLEND_ALPHA = 0
comptime TRAIL_BLEND_ADD = 1


struct TrailStyle(Copyable, Movable):
    var lifetime: Float64  # seconds a point lives
    var min_step: Float64  # metres between points
    var max_points: Int
    var width_curve: List[Float64]  # metres, over age 0 .. 1 at equal steps
    var color_start: List[Float64]  # r g b a at age 0
    var color_mid: List[Float64]
    var color_end: List[Float64]
    var blend: Int  # TRAIL_BLEND_ALPHA or TRAIL_BLEND_ADD
    var flat: Bool  # True: the strip lies flat (its width along tangent x up, a tyre mark); False: it faces the camera

    def __init__(
        out self, lifetime: Float64, min_step: Float64, max_points: Int, var width_curve: List[Float64],
        var color_start: List[Float64], var color_mid: List[Float64], var color_end: List[Float64], blend: Int, flat: Bool = False,
    ) raises:
        if lifetime <= 0.0 or min_step <= 0.0 or max_points < 2:
            raise Error("TrailStyle: lifetime > 0, min_step > 0 and max_points >= 2")
        if len(width_curve) < 1 or len(width_curve) > 16:
            raise Error("TrailStyle: width_curve has 1 to 16 values")
        if len(color_start) != 4 or len(color_mid) != 4 or len(color_end) != 4:
            raise Error("TrailStyle: colours are r g b a")
        if blend != TRAIL_BLEND_ALPHA and blend != TRAIL_BLEND_ADD:
            raise Error("TrailStyle: blend is TRAIL_BLEND_ALPHA or TRAIL_BLEND_ADD")
        self.lifetime = lifetime
        self.min_step = min_step
        self.max_points = max_points
        self.width_curve = width_curve^
        self.color_start = color_start^
        self.color_mid = color_mid^
        self.color_end = color_end^
        self.blend = blend
        self.flat = flat


struct Trail(Movable):
    var style: TrailStyle
    var px: List[Float64]
    var py: List[Float64]
    var pz: List[Float64]
    var birth: List[Float64]
    var dropped: Int  # points dropped over max_points

    def __init__(out self, var style: TrailStyle):
        self.style = style^
        self.px = List[Float64]()
        self.py = List[Float64]()
        self.pz = List[Float64]()
        self.birth = List[Float64]()
        self.dropped = 0

    def points(self) -> Int:
        return len(self.px)

    def move_to(mut self, time: Float64, x: Float64, y: Float64, z: Float64):
        var n = len(self.px)
        if n > 0:
            var dx = x - self.px[n - 1]
            var dy = y - self.py[n - 1]
            var dz = z - self.pz[n - 1]
            if dx * dx + dy * dy + dz * dz < self.style.min_step * self.style.min_step:
                return
        if n >= self.style.max_points:
            self._drop_front(1)
            self.dropped += 1
        self.px.append(x)
        self.py.append(y)
        self.pz.append(z)
        self.birth.append(time)

    def expire(mut self, time: Float64):
        var k = 0
        while k < len(self.birth) and time - self.birth[k] >= self.style.lifetime:
            k += 1
        self._drop_front(k)

    def _drop_front(mut self, k: Int):
        if k <= 0:
            return
        var n = len(self.px)
        for i in range(k, n):
            self.px[i - k] = self.px[i]
            self.py[i - k] = self.py[i]
            self.pz[i - k] = self.pz[i]
            self.birth[i - k] = self.birth[i]
        for _ in range(k):
            _ = self.px.pop()
            _ = self.py.pop()
            _ = self.pz.pop()
            _ = self.birth.pop()

    def width_at(self, i: Int, time: Float64) -> Float64:
        return curve_at(self.style.width_curve, (time - self.birth[i]) / self.style.lifetime)

    def _point(self, i: Int, time: Float64, mut out: List[Float32]):
        var n = len(self.px)
        var t = (time - self.birth[i]) / self.style.lifetime
        out.append(Float32(self.px[i]))
        out.append(Float32(self.py[i]))
        out.append(Float32(self.pz[i]))
        out.append(Float32(curve_at(self.style.width_curve, t)))
        for j in range(4):
            out.append(Float32(color3(self.style.color_start, self.style.color_mid, self.style.color_end, t, j)))
        var a = max(i - 1, 0)
        var b = min(i + 1, n - 1)
        var tx = self.px[b] - self.px[a]
        var ty = self.py[b] - self.py[a]
        var tz = self.pz[b] - self.pz[a]
        var l = sqrt(tx * tx + ty * ty + tz * tz)
        if l < 1e-12:
            tx = 1.0
            ty = 0.0
            tz = 0.0
            l = 1.0
        out.append(Float32(tx / l))
        out.append(Float32(ty / l))
        out.append(Float32(tz / l))
        out.append(Float32(1.0) if self.style.flat else Float32(0.0))


struct TrailSystem(Movable):
    var trails: List[Trail]
    var key: List[Float64]  # scratch: sort keys
    var who: List[Int]  # scratch: trail * 2^32 + first point of the segment

    def __init__(out self):
        self.trails = List[Trail]()
        self.key = List[Float64]()
        self.who = List[Int]()

    def add(mut self, var style: TrailStyle) -> Int:
        self.trails.append(Trail(style^))
        return len(self.trails) - 1

    def expire(mut self, time: Float64):
        for i in range(len(self.trails)):
            self.trails[i].expire(time)

    def segments(self) -> Int:
        var n = 0
        for i in range(len(self.trails)):
            n += max(self.trails[i].points() - 1, 0)
        return n

    def dropped(self) -> Int:
        var n = 0
        for i in range(len(self.trails)):
            n += self.trails[i].dropped
        return n

    def pack(
        mut self, time: Float64, cam_x: Float64, cam_y: Float64, cam_z: Float64, fx: Float64, fy: Float64, fz: Float64,
        mut out: List[Float32], max_segments: Int,
    ) -> Tuple[Int, Int]:
        """Append the segment records (TRAIL_SEGMENT_FLOATS each) to `out`: alpha first, sorted far to near, then additive.
        At most `max_segments` in all. Returns (alpha count, additive count)."""
        self.key.clear()
        self.who.clear()
        for e in range(len(self.trails)):
            ref tr = self.trails[e]
            if tr.style.blend == TRAIL_BLEND_ADD:
                continue
            for i in range(tr.points() - 1):
                var mx = (tr.px[i] + tr.px[i + 1]) * 0.5 - cam_x
                var my = (tr.py[i] + tr.py[i + 1]) * 0.5 - cam_y
                var mz = (tr.pz[i] + tr.pz[i + 1]) * 0.5 - cam_z
                self.key.append(mx * fx + my * fy + mz * fz)
                self.who.append(e * 4294967296 + i)
        var order = List[Int](capacity=len(self.key))
        for i in range(len(self.key)):
            order.append(i)
        merge_order(order, self.key)
        var n_alpha = 0
        for k in range(len(order)):
            if n_alpha >= max_segments:
                break
            var w = self.who[order[k]]
            ref tr = self.trails[w // 4294967296]
            tr._point(w % 4294967296, time, out)
            tr._point(w % 4294967296 + 1, time, out)
            n_alpha += 1
        var n_add = 0
        for e in range(len(self.trails)):
            ref tr = self.trails[e]
            if tr.style.blend != TRAIL_BLEND_ADD:
                continue
            for i in range(tr.points() - 1):
                if n_alpha + n_add >= max_segments:
                    return (n_alpha, n_add)
                tr._point(i, time, out)
                tr._point(i + 1, time, out)
                n_add += 1
        return (n_alpha, n_add)
