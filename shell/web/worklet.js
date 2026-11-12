// AudioWorklet side of the ring: drains interleaved stereo f32 frames that the
// main thread rendered with miniaudio-mojo (web_render) into a SharedArrayBuffer.
//
// Ring layout (shared with main.js):
//   ctl  = Int32Array(sab, 0, 4): [0] write index, [1] read index (frames, mod capacity),
//                                 [2] under-run count, [3] frames played
//   data = Float32Array(sab, 16, capacity * 2)
// Under-run policy: if fewer than 128 frames are buffered the block is silence,
// nothing is consumed, and ctl[2] is incremented.
// Refill: when less than half the ring is buffered the worklet posts a message,
// at most once per 8 blocks; the main thread renders on it. (requestAnimationFrame
// alone stops in a background tab; messages keep arriving.)
// Without a SharedArrayBuffer (a host that cannot send COOP/COEP headers, e.g. GitHub Pages) the processor is created
// with no `sab`: it keeps the ring itself, the main thread posts Float32Array blocks of interleaved frames, and every
// refill request carries { available, played, underruns } because the main thread cannot read the counters.
class RingPlayer extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const { sab, capacity } = options.processorOptions;
    this.capacity = capacity;
    this.sinceAsk = 8;
    this.shared = !!sab;
    if (this.shared) {
      this.ctl = new Int32Array(sab, 0, 4);
      this.data = new Float32Array(sab, 16, capacity * 2);
    } else {
      this.ctl = new Int32Array(4);
      this.data = new Float32Array(capacity * 2);
      this.port.onmessage = (e) => {
        const block = e.data;
        let w = this.ctl[0];
        const free = this.capacity - 1 - ((w - this.ctl[1] + this.capacity) % this.capacity);
        const frames = Math.min(block.length / 2, free); // frames that do not fit are dropped, never overwrite unplayed ones
        for (let i = 0; i < frames; i++) {
          this.data[2 * w] = block[2 * i];
          this.data[2 * w + 1] = block[2 * i + 1];
          w = (w + 1) % this.capacity;
        }
        this.ctl[0] = w;
      };
    }
  }

  load(i) { return this.shared ? Atomics.load(this.ctl, i) : this.ctl[i]; }
  store(i, v) { if (this.shared) Atomics.store(this.ctl, i, v); else this.ctl[i] = v; }
  add(i, v) { if (this.shared) Atomics.add(this.ctl, i, v); else this.ctl[i] += v; }

  process(inputs, outputs) {
    const out = outputs[0];
    const left = out[0];
    const right = out[1] ?? out[0];
    const frames = left.length;
    const w = this.load(0);
    let r = this.load(1);
    const available = (w - r + this.capacity) % this.capacity;
    if (available < this.capacity / 2 && ++this.sinceAsk >= 8) {
      this.port.postMessage(this.shared ? available : { available, played: this.ctl[3], underruns: this.ctl[2] });
      this.sinceAsk = 0;
    }
    if (available < frames) {
      left.fill(0);
      right.fill(0);
      this.add(2, 1);
      return true;
    }
    for (let i = 0; i < frames; i++) {
      left[i] = this.data[2 * r];
      right[i] = this.data[2 * r + 1];
      r = (r + 1) % this.capacity;
    }
    this.store(1, r);
    this.add(3, frames);
    return true;
  }
}

registerProcessor("ring-player", RingPlayer);
