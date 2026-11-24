"""Loudness of the master bus in LUFS (ITU-R BS.1770-4), a debug readout (ludens-engine #120). Standard library only.

K-weighting is the two filters of BS.1770 at 48 kHz (their published coefficients): a high shelf, then a 38 Hz high
pass. Each channel's mean square is summed (L and R weight 1.0). Power is kept per 100 ms; the momentary value is the
last 400 ms (4 such blocks), and the integrated value gates the 400 ms blocks (step 100 ms) at -70 LUFS and then at
10 LU under the mean of what passed.

Only the sample rate 48000 is supported (the coefficients are for it). The meter reads the master bus and changes no
sample, so it is not part of the byte-compared output."""
from std.math import log10

comptime LUFS_FLOOR: Float64 = -120.0  # what a silent signal reads
comptime LUFS_BLOCK_FRAMES = 4800  # 100 ms at 48 kHz


struct _Biquad(Copyable, Movable):
    var b0: Float64
    var b1: Float64
    var b2: Float64
    var a1: Float64
    var a2: Float64
    var x1: Float64
    var x2: Float64
    var y1: Float64
    var y2: Float64

    def __init__(out self, b0: Float64, b1: Float64, b2: Float64, a1: Float64, a2: Float64):
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
        self.x1 = 0.0
        self.x2 = 0.0
        self.y1 = 0.0
        self.y2 = 0.0

    def tick(mut self, x: Float64) -> Float64:
        var y = self.b0 * x + self.b1 * self.x1 + self.b2 * self.x2 - self.a1 * self.y1 - self.a2 * self.y2
        self.x2 = self.x1
        self.x1 = x
        self.y2 = self.y1
        self.y1 = y
        return y


def _lufs(power: Float64) -> Float64:
    if power <= 0.0:
        return LUFS_FLOOR
    return -0.691 + 10.0 * log10(power)


struct LoudnessMeter(Movable):
    var shelf_l: _Biquad
    var shelf_r: _Biquad
    var high_l: _Biquad
    var high_r: _Biquad
    var acc: Float64  # sum of K-weighted squares (both channels) in the current 100 ms block
    var acc_n: Int
    var blocks: List[Float64]  # mean power of each finished 100 ms block (both channels summed)

    def __init__(out self):
        self.shelf_l = _shelf()
        self.shelf_r = _shelf()
        self.high_l = _high_pass()
        self.high_r = _high_pass()
        self.acc = 0.0
        self.acc_n = 0
        self.blocks = List[Float64]()

    def reset(mut self):
        self.shelf_l = _shelf()
        self.shelf_r = _shelf()
        self.high_l = _high_pass()
        self.high_r = _high_pass()
        self.acc = 0.0
        self.acc_n = 0
        self.blocks.clear()

    def feed(mut self, stereo: List[Float32], frames: Int):
        """Add `frames` interleaved stereo frames."""
        for i in range(frames):
            var l = self.high_l.tick(self.shelf_l.tick(Float64(stereo[2 * i])))
            var r = self.high_r.tick(self.shelf_r.tick(Float64(stereo[2 * i + 1])))
            self.acc += l * l + r * r
            self.acc_n += 1
            if self.acc_n == LUFS_BLOCK_FRAMES:
                self.blocks.append(self.acc / Float64(LUFS_BLOCK_FRAMES))
                self.acc = 0.0
                self.acc_n = 0

    def momentary(self) -> Float64:
        """Loudness of the last 400 ms in LUFS (fewer blocks if the signal is shorter); `LUFS_FLOOR` if there is none."""
        var n = len(self.blocks)
        if n == 0:
            return LUFS_FLOOR
        var k = 4 if n >= 4 else n
        var sum = Float64(0.0)
        for i in range(n - k, n):
            sum += self.blocks[i]
        return _lufs(sum / Float64(k))

    def integrated(self) -> Float64:
        """Gated loudness of everything fed since `reset`, in LUFS; `LUFS_FLOOR` before 400 ms or if all is gated out."""
        var n = len(self.blocks) - 3
        if n < 1:
            return LUFS_FLOOR
        var powers = List[Float64]()
        for i in range(n):
            powers.append((self.blocks[i] + self.blocks[i + 1] + self.blocks[i + 2] + self.blocks[i + 3]) * 0.25)
        var sum = Float64(0.0)
        var count = 0
        for p in powers:
            if _lufs(p) > -70.0:
                sum += p
                count += 1
        if count == 0:
            return LUFS_FLOOR
        var gate = _lufs(sum / Float64(count)) - 10.0
        sum = 0.0
        count = 0
        for p in powers:
            if _lufs(p) > gate:
                sum += p
                count += 1
        if count == 0:
            return LUFS_FLOOR
        return _lufs(sum / Float64(count))


def _shelf() -> _Biquad:
    return _Biquad(1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585)


def _high_pass() -> _Biquad:
    return _Biquad(1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621)
