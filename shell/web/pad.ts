// Gamepad -> the events the app takes: every button as a key code (keys.ts padButtonKey), every axis as an AXIS event with its raw
// value, and the right stick as a camera turn. Which button or stick does what is the game's action map (game/data/demo.actions),
// and the dead zone of the move stick is the map's; none of that is decided here. No DOM and no wasm in here, so
// scripts/test_pad.mjs can run it under node. Touch is the virtual pad kit, vpad.ts.

// Gamepad and on-screen pad buttons are sent as key events (so the game gets press edges): button b of device d is the key code
// PAD_BUTTON_BASE + PAD_BUTTON_STRIDE * d + b. Devices 0..2 are gamepads (by index), 3 is the on-screen pad. Axes are AXIS events
// (keys.ts EV.AXIS). Same numbers as game/action_map.mojo.
export const PAD_BUTTON_BASE = 400, PAD_BUTTON_STRIDE = 20, GAMEPADS = 3, VPAD_DEVICE = 3;
export const padButtonKey = (device: number, button: number) => PAD_BUTTON_BASE + PAD_BUTTON_STRIDE * device + button;

const DEADZONE = 0.3;
const LOOK_PX_PER_S = 900; // right stick at full tilt: this many pixels of mouse movement a second

export interface Sink {
  key(code: number, down: boolean): void;
  axis?(device: number, axis: number, value: number): void; // raw -1..1, y down, sent when it changes
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

/** The key codes of the buttons a gamepad of index `device` holds down. `buttons[i]` is whether button i is pressed. */
export function padButtons(device: number, buttons: readonly boolean[]): Set<number> {
  const keys = new Set<number>();
  for (let i = 0; i < buttons.length; i++) if (buttons[i]) keys.add(padButtonKey(device, i));
  return keys;
}

/** Camera turn in pixels from the right stick over `dtMs`. */
export function padLook(axes: readonly number[], dtMs: number): [number, number] {
  const dead = (v: number) => (Math.abs(v) < DEADZONE ? 0 : v);
  const k = (LOOK_PX_PER_S * dtMs) / 1000;
  return [dead(axes[2] ?? 0) * k, dead(axes[3] ?? 0) * k];
}

/** One gamepad, polled once a frame. `device` is the gamepad's index; a gamepad past GAMEPADS is ignored. */
export class PadInput {
  private keys = new HeldKeys();
  private looking = false;
  private axes: number[] = [];
  private device: number;
  constructor(device = 0) { this.device = device; }
  poll(axes: readonly number[], buttons: readonly boolean[], dtMs: number, sink: Sink) {
    if (this.device >= GAMEPADS) return;
    this.keys.set(padButtons(this.device, buttons), sink);
    for (let a = 0; a < Math.min(axes.length, 6); a++) {
      if ((this.axes[a] ?? 0) !== axes[a]) { this.axes[a] = axes[a]; sink.axis?.(this.device, a, axes[a]); }
    }
    const [dx, dy] = padLook(axes, dtMs);
    if (dx !== 0 || dy !== 0) { this.looking = true; sink.look(dx, dy); }
    else if (this.looking) { this.looking = false; sink.lookEnd(); }
  }
  /** The pad went away: let go of everything it held. */
  release(sink: Sink) {
    if (this.device >= GAMEPADS) return;
    this.poll(this.axes.map(() => 0), [], 0, sink);
  }
}
