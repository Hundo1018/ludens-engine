// Gamepad and touch -> the key and pointer events the app already takes (GLFW codes, see keys.ts).
// No DOM and no wasm in here, so scripts/test_pad.mjs can run it under node.
//
// Gamepad (standard mapping): left stick or d-pad moves, right stick turns the camera, A jumps, Start pauses, Y restarts.
// Touch: a drag that starts on the left half of the canvas is a move stick, one that starts on the right half turns the
// camera, and a short tap on the right half jumps.

export const KEY = { W: 87, A: 65, S: 83, D: 68, SPACE: 32, P: 80, R: 82 } as const;
const DEADZONE = 0.3;
const LOOK_PX_PER_S = 900; // right stick at full tilt: this many pixels of mouse movement a second
const STICK_DEAD = 12;
const TAP_MS = 250;
const TAP_PX = 10;

export interface Sink {
  key(code: number, down: boolean): void;
  look(dx: number, dy: number): void; // camera turn in pixels; (0, 0) is never sent
  lookEnd(): void; // the turn stopped
}

/** Holds a set of virtual keys down and reports only the changes. */
export class HeldKeys {
  private held = new Set<number>();
  set(wanted: Set<number>, sink: Sink) {
    for (const k of this.held) if (!wanted.has(k)) { this.held.delete(k); sink.key(k, false); }
    for (const k of wanted) if (!this.held.has(k)) { this.held.add(k); sink.key(k, true); }
  }
}

/** The keys a gamepad state holds down. `buttons[i]` is whether button i is pressed. */
export function padKeys(axes: readonly number[], buttons: readonly boolean[]): Set<number> {
  const keys = new Set<number>();
  const x = axes[0] ?? 0, y = axes[1] ?? 0;
  if (y < -DEADZONE || buttons[12]) keys.add(KEY.W);
  if (y > DEADZONE || buttons[13]) keys.add(KEY.S);
  if (x < -DEADZONE || buttons[14]) keys.add(KEY.A);
  if (x > DEADZONE || buttons[15]) keys.add(KEY.D);
  if (buttons[0]) keys.add(KEY.SPACE);
  if (buttons[9]) keys.add(KEY.P);
  if (buttons[3]) keys.add(KEY.R);
  return keys;
}

/** Camera turn in pixels from the right stick over `dtMs`. */
export function padLook(axes: readonly number[], dtMs: number): [number, number] {
  const dead = (v: number) => (Math.abs(v) < DEADZONE ? 0 : v);
  const k = (LOOK_PX_PER_S * dtMs) / 1000;
  return [dead(axes[2] ?? 0) * k, dead(axes[3] ?? 0) * k];
}

/** One gamepad, polled once a frame. */
export class PadInput {
  private keys = new HeldKeys();
  private looking = false;
  poll(axes: readonly number[], buttons: readonly boolean[], dtMs: number, sink: Sink) {
    this.keys.set(padKeys(axes, buttons), sink);
    const [dx, dy] = padLook(axes, dtMs);
    if (dx !== 0 || dy !== 0) { this.looking = true; sink.look(dx, dy); }
    else if (this.looking) { this.looking = false; sink.lookEnd(); }
  }
  /** The pad went away: let go of everything it held. */
  release(sink: Sink) { this.poll([], [], 0, sink); }
}

interface Touch { side: "move" | "look"; x0: number; y0: number; x: number; y: number; t0: number; far: boolean }

/** Touches on the canvas. Positions are canvas pixels; `width` splits it into the move half and the look half. */
export class TouchInput {
  private touches = new Map<number, Touch>();
  private keys = new HeldKeys();
  start(id: number, x: number, y: number, width: number, now: number) {
    this.touches.set(id, { side: x < width / 2 ? "move" : "look", x0: x, y0: y, x, y, t0: now, far: false });
  }
  move(id: number, x: number, y: number, sink: Sink) {
    const t = this.touches.get(id);
    if (!t) return;
    const dx = x - t.x, dy = y - t.y;
    t.x = x; t.y = y;
    if (Math.hypot(x - t.x0, y - t.y0) > TAP_PX) t.far = true;
    if (t.side === "look" && (dx !== 0 || dy !== 0)) sink.look(dx, dy);
    if (t.side === "move") this.keys.set(this.stickKeys(), sink);
  }
  end(id: number, now: number, sink: Sink) {
    const t = this.touches.get(id);
    if (!t) return;
    this.touches.delete(id);
    if (t.side === "look") {
      sink.lookEnd();
      if (!t.far && now - t.t0 <= TAP_MS) { sink.key(KEY.SPACE, true); sink.key(KEY.SPACE, false); }
    } else this.keys.set(this.stickKeys(), sink);
  }
  /** Focus was lost: forget every touch and let go of the keys. */
  release(sink: Sink) {
    const looking = [...this.touches.values()].some((t) => t.side === "look");
    this.touches.clear();
    this.keys.set(new Set(), sink);
    if (looking) sink.lookEnd();
  }
  private stickKeys(): Set<number> {
    const keys = new Set<number>();
    for (const t of this.touches.values()) {
      if (t.side !== "move") continue;
      const dx = t.x - t.x0, dy = t.y - t.y0;
      if (dy < -STICK_DEAD) keys.add(KEY.W);
      if (dy > STICK_DEAD) keys.add(KEY.S);
      if (dx < -STICK_DEAD) keys.add(KEY.A);
      if (dx > STICK_DEAD) keys.add(KEY.D);
    }
    return keys;
  }
}
