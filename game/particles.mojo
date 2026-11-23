"""Particle simulation on the CPU (#121). Emitter parameters are one row of the `particles` table
(`game/data/particles.schema`, accessors in `game/particles_table.mojo`); this file runs them.

Determinism: the only arithmetic is + - * / and sqrt on Float64, which are exactly rounded on native and on wasm64, and a
per-emitter splitmix64 stream. There is no sin, cos, exp or pow in the step (the cone's cosine is a Taylor sum). The
same seed, the same emitter rows and the same sequence of `step(dt, camera)` calls therefore give the same bytes on
both targets (`app/particles_parity.mojo` compares them).

Limits, all counted:
- `max_particles` of an emitter: a spawn past it is dropped (`dropped_budget`).
- `ParticleSystem.cap` over all emitters: a spawn past it is dropped (`dropped_cap`).
- LOD: the emission rate (and the size of a burst) is scaled by the camera distance, `lod_skipped` counts the
  particles that the full rate would have spawned and the scaled rate did not.

Order of a step: LOD scale, emission (rate, then bursts), then every live particle ages and moves (semi-implicit
Euler: velocity += gravity * dt, velocity /= 1 + drag * dt, position += velocity * dt). A particle spawned in a step moves
in that same step. A particle whose age reaches its life is removed by swapping the last particle into its place.
"""
from std.math import sqrt
from game.particles_table import ParticlesRow, PARTICLES_BLEND_ADD, PARTICLES_SCHEMA_TEXT, particles_row
from game.table import table_load

comptime PARTICLE_FLOATS = 12  # floats per particle in the GPU record: 3 x vec4
comptime TWO_POW_M53 = 1.1102230246251565e-16


struct Rng(Copyable, Movable):
    """splitmix64. One stream per emitter, so adding an emitter does not change another's particles."""

    var s: UInt64

    def __init__(out self, seed: UInt64):
        self.s = seed

    def next_u64(mut self) -> UInt64:
        self.s += UInt64(0x9E3779B97F4A7C15)
        var z = self.s
        z = (z ^ (z >> 30)) * UInt64(0xBF58476D1CE4E5B9)
        z = (z ^ (z >> 27)) * UInt64(0x94D049BB133111EB)
        return z ^ (z >> 31)

    def next_f(mut self) -> Float64:
        """Uniform in [0, 1), 53 random bits."""
        return Float64(self.next_u64() >> 11) * TWO_POW_M53


def cos_taylor(x: Float64) -> Float64:
    """cos(x) for 0 <= x <= pi by its Taylor series (+, *, / only), error below 1e-12."""
    var term = Float64(1.0)
    var sum = Float64(1.0)
    var x2 = x * x
    for k in range(1, 14):
        term = -term * x2 / Float64((2 * k - 1) * (2 * k))
        sum += term
    return sum


def _unit(x: Float64, y: Float64, z: Float64) -> List[Float64]:
    var l = sqrt(x * x + y * y + z * z)
    if l < 1e-12:
        return [0.0, 1.0, 0.0]
    return [x / l, y / l, z / l]


def curve_at(samples: List[Float64], t: Float64) -> Float64:
    """Piecewise linear through `samples` placed at equal steps of t in [0, 1]."""
    var n = len(samples)
    if n == 0:
        return 0.0
    if n == 1 or t <= 0.0:
        return samples[0]
    if t >= 1.0:
        return samples[n - 1]
    var f = t * Float64(n - 1)
    var i = Int(f)
    var u = f - Float64(i)
    return samples[i] + (samples[i + 1] - samples[i]) * u


def lod_scale(row: ParticlesRow, distance: Float64) -> Float64:
    """1 up to lod_near, lod_min from lod_far, linear between. lod_far = 0 turns the LOD off."""
    if row.lod_far <= 0.0 or distance <= row.lod_near:
        return 1.0
    if distance >= row.lod_far:
        return row.lod_min
    var u = (distance - row.lod_near) / (row.lod_far - row.lod_near)
    return 1.0 + (row.lod_min - 1.0) * u


struct Emitter(Movable):
    var row: ParticlesRow
    var origin: List[Float64]  # world position
    var axis: List[Float64]  # unit cone axis in the world
    var cos_cone: Float64
    var rng: Rng
    var playing: Bool
    var time: Float64
    var accum: Float64  # fractional particles owed at the LOD-scaled rate
    var accum_full: Float64  # the same at the full rate, to count what the LOD removed
    var pending: Int  # particles queued by `burst`, emitted at full count in the next step (no LOD, not counted as skipped)
    var next_burst: Float64
    # particles, one array per field
    var px: List[Float64]
    var py: List[Float64]
    var pz: List[Float64]
    var vx: List[Float64]
    var vy: List[Float64]
    var vz: List[Float64]
    var age: List[Float64]
    var life: List[Float64]
    var jit: List[Float64]
    # counters
    var spawned: Int
    var dropped_budget: Int
    var dropped_cap: Int
    var lod_skipped: Int

    def __init__(out self, var row: ParticlesRow, origin_x: Float64, origin_y: Float64, origin_z: Float64, seed: UInt64):
        self.axis = _unit(row.direction[0], row.direction[1], row.direction[2])
        self.cos_cone = cos_taylor(row.cone_deg * 0.017453292519943295)
        self.row = row^
        self.origin = [origin_x, origin_y, origin_z]
        self.rng = Rng(seed)
        self.playing = True
        self.time = 0.0
        self.accum = 0.0
        self.accum_full = 0.0
        self.pending = 0
        self.next_burst = 0.0 if self.row.burst_count > 0 else -1.0
        self.px = List[Float64]()
        self.py = List[Float64]()
        self.pz = List[Float64]()
        self.vx = List[Float64]()
        self.vy = List[Float64]()
        self.vz = List[Float64]()
        self.age = List[Float64]()
        self.life = List[Float64]()
        self.jit = List[Float64]()
        self.spawned = 0
        self.dropped_budget = 0
        self.dropped_cap = 0
        self.lod_skipped = 0

    def live(self) -> Int:
        return len(self.px)

    def burst(mut self, n: Int):
        """Queue n particles for the next step: all n, not scaled by the LOD and not counted in `lod_skipped`."""
        self.pending += n

    def _spawn(mut self, room: Int) -> Bool:
        """One particle, or a counted drop (False). `room` is what the system's cap still allows."""
        # the random draws are made even for a dropped spawn, so a drop does not shift later particles
        var life = self.row.lifetime_min + (self.row.lifetime_max - self.row.lifetime_min) * self.rng.next_f()
        var speed = self.row.speed_min + (self.row.speed_max - self.row.speed_min) * self.rng.next_f()
        var z = 1.0 - (1.0 - self.cos_cone) * self.rng.next_f()
        var cx = 1.0
        var cy = 0.0
        for _ in range(8):
            var a = self.rng.next_f() * 2.0 - 1.0
            var b = self.rng.next_f() * 2.0 - 1.0
            var d2 = a * a + b * b
            if d2 > 1e-6 and d2 <= 1.0:
                var l = sqrt(d2)
                cx = a / l
                cy = b / l
                break
        var jit = 1.0 - self.row.size_jitter * self.rng.next_f()
        if self.live() >= self.row.max_particles:
            self.dropped_budget += 1
            return False
        if room <= 0:
            self.dropped_cap += 1
            return False
        var s = sqrt(max(0.0, 1.0 - z * z))
        var ax = self.axis[0]
        var ay = self.axis[1]
        var az = self.axis[2]
        var hx = 0.0
        var hy = 1.0
        if abs(ay) > 0.99:
            hx = 1.0
            hy = 0.0
        var t1 = _unit(hy * az, -hx * az, hx * ay - hy * ax)  # cross(h, axis), h = (hx, hy, 0)
        var t2 = [ay * t1[2] - az * t1[1], az * t1[0] - ax * t1[2], ax * t1[1] - ay * t1[0]]
        var dx = ax * z + (t1[0] * cx + t2[0] * cy) * s
        var dy = ay * z + (t1[1] * cx + t2[1] * cy) * s
        var dz = az * z + (t1[2] * cx + t2[2] * cy) * s
        self.px.append(self.origin[0])
        self.py.append(self.origin[1])
        self.pz.append(self.origin[2])
        self.vx.append(dx * speed)
        self.vy.append(dy * speed)
        self.vz.append(dz * speed)
        self.age.append(0.0)
        self.life.append(life)
        self.jit.append(jit)
        self.spawned += 1
        return True

    def step(mut self, dt: Float64, cam_x: Float64, cam_y: Float64, cam_z: Float64, mut total: Int, cap: Int):
        """Emit, then move every live particle. `total` is the system's live count, updated here; `cap` its limit."""
        var dx = self.origin[0] - cam_x
        var dy = self.origin[1] - cam_y
        var dz = self.origin[2] - cam_z
        var scale = lod_scale(self.row, sqrt(dx * dx + dy * dy + dz * dz))
        var wanted = 0
        if self.playing:
            self.accum += self.row.rate * dt * scale
            self.accum_full += self.row.rate * dt
            var n = Int(self.accum)
            var n_full = Int(self.accum_full)
            self.accum -= Float64(n)
            self.accum_full -= Float64(n_full)
            self.lod_skipped += n_full - n
            wanted += n + self.pending
            self.pending = 0
            var end = self.time + dt
            while self.next_burst >= 0.0 and self.next_burst <= end:
                var scaled = Int(Float64(self.row.burst_count) * scale)
                wanted += scaled
                self.lod_skipped += self.row.burst_count - scaled
                if self.row.burst_every > 0.0:
                    self.next_burst += self.row.burst_every
                else:
                    self.next_burst = -1.0
            self.time = end
        for _ in range(wanted):
            if self._spawn(cap - total):
                total += 1
        # integrate
        var drag = 1.0 / (1.0 + self.row.drag * dt)
        var gx = self.row.gravity[0] * dt
        var gy = self.row.gravity[1] * dt
        var gz = self.row.gravity[2] * dt
        var i = 0
        while i < len(self.px):
            self.age[i] += dt
            if self.age[i] >= self.life[i]:
                var last = len(self.px) - 1
                self.px[i] = self.px[last]
                self.py[i] = self.py[last]
                self.pz[i] = self.pz[last]
                self.vx[i] = self.vx[last]
                self.vy[i] = self.vy[last]
                self.vz[i] = self.vz[last]
                self.age[i] = self.age[last]
                self.life[i] = self.life[last]
                self.jit[i] = self.jit[last]
                _ = self.px.pop()
                _ = self.py.pop()
                _ = self.pz.pop()
                _ = self.vx.pop()
                _ = self.vy.pop()
                _ = self.vz.pop()
                _ = self.age.pop()
                _ = self.life.pop()
                _ = self.jit.pop()
                total -= 1
                continue
            self.vx[i] = (self.vx[i] + gx) * drag
            self.vy[i] = (self.vy[i] + gy) * drag
            self.vz[i] = (self.vz[i] + gz) * drag
            self.px[i] += self.vx[i] * dt
            self.py[i] += self.vy[i] * dt
            self.pz[i] += self.vz[i] * dt
            i += 1


def _fnv(h: UInt64, bits: UInt64) -> UInt64:
    return (h ^ bits) * UInt64(0x100000001B3)


def _merge_order(mut order: List[Int], key: List[Float64]):
    """Sort `order` by key descending, ties by the smaller index first. Bottom-up merge sort: O(n log n), the result
    does not depend on the sort's stability because the comparison is a total order."""
    var n = len(order)
    var tmp = List[Int](length=n, fill=0)
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var a = lo
            var b = mid
            var o = lo
            while a < mid and b < hi:
                var ia = order[a]
                var ib = order[b]
                if key[ia] > key[ib] or (key[ia] == key[ib] and ia < ib):
                    tmp[o] = ia
                    a += 1
                else:
                    tmp[o] = ib
                    b += 1
                o += 1
            while a < mid:
                tmp[o] = order[a]
                a += 1
                o += 1
            while b < hi:
                tmp[o] = order[b]
                b += 1
                o += 1
            lo += 2 * width
        for i in range(n):
            order[i] = tmp[i]
        width *= 2


struct ParticleSystem(Movable):
    """The emitters of a scene, a global cap on live particles, and the counters."""

    var emitters: List[Emitter]
    var cap: Int
    var live_total: Int
    var key: List[Float64]  # scratch: sort keys, reused every frame
    var who: List[Int]  # scratch: (emitter, particle) of each sortable entry, packed as emitter * 2^32 + index

    def __init__(out self, cap: Int):
        self.emitters = List[Emitter]()
        self.cap = cap
        self.live_total = 0
        self.key = List[Float64]()
        self.who = List[Int]()

    def add(mut self, var row: ParticlesRow, x: Float64, y: Float64, z: Float64, seed: UInt64) -> Int:
        """An emitter at (x, y, z); its random stream starts from `seed`. Returns its index."""
        self.emitters.append(Emitter(row^, x, y, z, seed))
        return len(self.emitters) - 1

    def add_component(mut self, var c: ParticlesComponent, x: Float64, y: Float64, z: Float64) -> Int:
        """An emitter from a scene component, at the entity's position."""
        var i = self.add(c.row^, x, y, z, c.seed)
        self.emitters[i].playing = c.playing
        return i

    def step(mut self, dt: Float64, cam_x: Float64, cam_y: Float64, cam_z: Float64):
        for i in range(len(self.emitters)):
            self.emitters[i].step(dt, cam_x, cam_y, cam_z, self.live_total, self.cap)

    def dropped_budget(self) -> Int:
        var n = 0
        for i in range(len(self.emitters)):
            n += self.emitters[i].dropped_budget
        return n

    def dropped_cap(self) -> Int:
        var n = 0
        for i in range(len(self.emitters)):
            n += self.emitters[i].dropped_cap
        return n

    def lod_skipped(self) -> Int:
        var n = 0
        for i in range(len(self.emitters)):
            n += self.emitters[i].lod_skipped
        return n

    def state_hash(self) -> UInt64:
        """FNV-1a over the bit patterns of every particle's position, velocity and age, emitters in order."""
        var h = UInt64(0xCBF29CE484222325)
        for e in range(len(self.emitters)):
            ref em = self.emitters[e]
            h = _fnv(h, UInt64(len(em.px)))
            for i in range(len(em.px)):
                h = _fnv(h, UInt64(em.px[i].to_bits()))
                h = _fnv(h, UInt64(em.py[i].to_bits()))
                h = _fnv(h, UInt64(em.pz[i].to_bits()))
                h = _fnv(h, UInt64(em.vx[i].to_bits()))
                h = _fnv(h, UInt64(em.vy[i].to_bits()))
                h = _fnv(h, UInt64(em.vz[i].to_bits()))
                h = _fnv(h, UInt64(em.age[i].to_bits()))
        return h

    def pack(
        mut self, cam_x: Float64, cam_y: Float64, cam_z: Float64, fx: Float64, fy: Float64, fz: Float64,
        mut out: List[Float32], max_records: Int,
    ) -> Tuple[Int, Int]:
        """Append the GPU records (PARTICLE_FLOATS floats each: [x y z size] [r g b a] [layer frame cols rows]) to `out`:
        first the alpha-blended particles of every emitter, sorted far to near along the camera's forward (fx, fy, fz),
        then the additive ones in emitter order (addition does not depend on order). At most `max_records` in all,
        alpha first. Returns (alpha count, additive count)."""
        self.key.clear()
        self.who.clear()
        for e in range(len(self.emitters)):
            ref em = self.emitters[e]
            if em.row.blend == PARTICLES_BLEND_ADD:
                continue
            for i in range(len(em.px)):
                self.key.append((em.px[i] - cam_x) * fx + (em.py[i] - cam_y) * fy + (em.pz[i] - cam_z) * fz)
                self.who.append(e * 4294967296 + i)
        var order = List[Int](capacity=len(self.key))
        for i in range(len(self.key)):
            order.append(i)
        _merge_order(order, self.key)
        var n_alpha = 0
        for k in range(len(order)):
            if n_alpha >= max_records:
                break
            var w = self.who[order[k]]
            self._record(w // 4294967296, w % 4294967296, out)
            n_alpha += 1
        var n_add = 0
        for e in range(len(self.emitters)):
            if self.emitters[e].row.blend != PARTICLES_BLEND_ADD:
                continue
            for i in range(len(self.emitters[e].px)):
                if n_alpha + n_add >= max_records:
                    return (n_alpha, n_add)
                self._record(e, i, out)
                n_add += 1
        return (n_alpha, n_add)

    def _record(self, e: Int, i: Int, mut out: List[Float32]):
        ref em = self.emitters[e]
        var t = em.age[i] / em.life[i]
        var size = curve_at(em.row.size_curve, t) * em.jit[i]
        var u = t * 2.0
        var cols = em.row.flipbook_cols
        var rows = em.row.flipbook_rows
        var frame = min(Int(t * Float64(cols * rows)), cols * rows - 1)
        out.append(Float32(em.px[i]))
        out.append(Float32(em.py[i]))
        out.append(Float32(em.pz[i]))
        out.append(Float32(size))
        if t < 0.5:
            for j in range(4):
                out.append(Float32(em.row.color_start[j] + (em.row.color_mid[j] - em.row.color_start[j]) * u))
        else:
            u -= 1.0
            for j in range(4):
                out.append(Float32(em.row.color_mid[j] + (em.row.color_end[j] - em.row.color_mid[j]) * u))
        out.append(Float32(em.row.layer))
        out.append(Float32(frame))
        out.append(Float32(cols))
        out.append(Float32(rows))


def float_hash(v: List[Float32]) -> UInt64:
    """FNV-1a over the bit patterns of a float list: the bytes the particle pass uploads."""
    var h = UInt64(0xCBF29CE484222325)
    for i in range(len(v)):
        h = _fnv(h, UInt64(v[i].to_bits()))
    return h


struct ParticlesComponent(Movable):
    """The scene component `particles` (docs/scene-format.md 8a): the emitter's fields, plus `seed` and `playing`."""

    var row: ParticlesRow
    var seed: UInt64
    var playing: Bool

    def __init__(out self, var row: ParticlesRow, seed: UInt64, playing: Bool):
        self.row = row^
        self.seed = seed
        self.playing = playing


def particles_component(rows: String, file: String = "particles component") raises -> ParticlesComponent:
    """Read the rows of one entity's `particles` component, `particles.<field> = <value>` per line (the scene layer has
    already removed the entity's path). `particles.seed` and `particles.playing` are the component's own; every other
    row is a field of the `particles` table and is checked by the same schema (range, kind, required `size_curve`).
    A problem raises an error that names `file` and the line."""
    var table_text = String("ludens-table 1 schema 1\n")
    var seed = UInt64(1)
    var playing = True
    var lines = rows.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i].strip())
        if line.byte_length() == 0 or line.startswith("#"):
            continue
        var eq = line.find("=")
        if eq < 0:
            raise Error(file + ":" + String(i + 1) + ": expected `particles.<field> = <value>`, got `" + line + "`")
        var key = String(line[byte=:eq].strip())
        var value = String(line[byte = eq + 1 :].strip())
        if not key.startswith("particles."):
            raise Error(file + ":" + String(i + 1) + ": `" + key + "` is not a `particles.` row")
        var field = String(key[byte = 10 :])
        if field == "seed":
            seed = UInt64(Int(atol(value)))
        elif field == "playing":
            if value != "true" and value != "false":
                raise Error(file + ":" + String(i + 1) + ": particles.playing is `true` or `false`, got `" + value + "`")
            playing = value == "true"
        else:
            table_text += "particles.main." + field + " = " + value + "\n"
    var t = table_load(PARTICLES_SCHEMA_TEXT, "game/data/particles.schema", table_text, file)
    return ParticlesComponent(particles_row(t, "main"), seed, playing)
