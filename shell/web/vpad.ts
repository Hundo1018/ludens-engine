// Virtual pad kit, core: on-screen sticks and buttons for touch players, as state and events only.
// No DOM, no wasm and no imports, so scripts/test_vpad.mjs runs it under node. shell/web/vpad_view.ts draws it.
//
// A game describes its controls as data (`PadLayout`) and receives the same events a keyboard and mouse would give:
// keys going down and up, and camera turns in pixels. A stick also reports its vector (`PadSink.stick`), for a game
// that reads an analog direction; `keys` on a stick turns the vector into four keys, eight directions.
//
// Every pointer belongs to the one control it went down on until it is lifted. A stick takes one pointer; its centre
// is where that finger landed, so the thumb never has to find a fixed spot. A button is down while any finger is on it.
// A finger that goes down on nothing (the canvas) turns the camera.

/** Distance in CSS pixels from the named viewport edges; the view adds the safe-area inset. */
export interface Placement { left?: number; right?: number; top?: number; bottom?: number }

export interface StickSpec {
  id: string;
  radius: number; // CSS pixels: the knob stops here, and here the vector has length 1
  dead?: number; // 0..1 of the radius inside which the vector is zero (default 0.2)
  keys?: { up: number; down: number; left: number; right: number };
  at: Placement; // where the stick rests when no finger is on it
  zone?: { width: string; height: string }; // CSS size of the area that takes the finger (default 46vw by 60vh)
}

export interface ButtonSpec {
  id: string;
  key: number;
  label: string;
  size: number; // CSS pixels, diameter
  at: Placement;
}

export interface PadLayout {
  sticks: StickSpec[];
  buttons: ButtonSpec[];
  look?: { tapKey?: number }; // a drag that starts on no control turns the camera; a short tap can press a key
}

export interface PadSink {
  key(code: number, down: boolean): void;
  look(dx: number, dy: number): void; // camera turn in pixels; (0, 0) is never sent
  lookEnd(): void;
  stick?(id: string, x: number, y: number): void; // -1..1, y down like the Gamepad API; sent on change
}

export interface StickState { active: boolean; ox: number; oy: number; dx: number; dy: number; x: number; y: number }

const DEFAULT_DEAD = 0.2;
const DIAGONAL = Math.sin(Math.PI / 8); // a direction counts on an axis from 22.5 degrees off the other axis
const TAP_MS = 250;
const TAP_PX = 10;

/** Knob offset in pixels (clamped to the radius) and the vector it stands for. */
export function stickVector(dx: number, dy: number, radius: number, dead = DEFAULT_DEAD): { dx: number; dy: number; x: number; y: number } {
  const len = Math.hypot(dx, dy);
  if (len > radius) { dx = (dx / len) * radius; dy = (dy / len) * radius; }
  const held = Math.min(len, radius); // length of the clamped offset
  const mag = held / radius;
  if (held === 0 || mag <= dead) return { dx, dy, x: 0, y: 0 };
  const out = (mag - dead) / (1 - dead); // 0 at the edge of the dead zone, 1 at the radius
  return { dx, dy, x: (dx / held) * out, y: (dy / held) * out };
}

/** The keys a stick vector holds: one of eight directions, none at rest. */
export function vectorKeys(x: number, y: number, keys: { up: number; down: number; left: number; right: number }): number[] {
  const m = Math.hypot(x, y);
  if (m === 0) return [];
  const out: number[] = [];
  if (y / m < -DIAGONAL) out.push(keys.up);
  if (y / m > DIAGONAL) out.push(keys.down);
  if (x / m < -DIAGONAL) out.push(keys.left);
  if (x / m > DIAGONAL) out.push(keys.right);
  return out;
}

type Owner =
  | { kind: "stick"; id: string }
  | { kind: "button"; id: string }
  | { kind: "look"; x0: number; y0: number; x: number; y: number; t0: number; far: boolean };

export class VirtualPad {
  private owner = new Map<number, Owner>();
  private sticks = new Map<string, { spec: StickSpec; pointer: number | null; state: StickState }>();
  private buttons = new Map<string, { spec: ButtonSpec; pointers: Set<number> }>();
  private held = new Set<number>();
  private looking: number | null = null;
  readonly layout: PadLayout;
  private sink: PadSink;

  constructor(layout: PadLayout, sink: PadSink) {
    this.layout = layout;
    this.sink = sink;
    for (const spec of layout.sticks) this.sticks.set(spec.id, { spec, pointer: null, state: { active: false, ox: 0, oy: 0, dx: 0, dy: 0, x: 0, y: 0 } });
    for (const spec of layout.buttons) this.buttons.set(spec.id, { spec, pointers: new Set() });
  }

  /** A finger went down in a stick's zone. False if the stick already has a finger: the caller leaves that touch alone. */
  stickDown(id: string, pointer: number, x: number, y: number): boolean {
    const s = this.sticks.get(id);
    if (!s || s.pointer !== null || this.owner.has(pointer)) return false;
    s.pointer = pointer;
    s.state = { active: true, ox: x, oy: y, dx: 0, dy: 0, x: 0, y: 0 };
    this.owner.set(pointer, { kind: "stick", id });
    return true;
  }

  buttonDown(id: string, pointer: number): boolean {
    const b = this.buttons.get(id);
    if (!b || this.owner.has(pointer)) return false;
    b.pointers.add(pointer);
    this.owner.set(pointer, { kind: "button", id });
    this.sync();
    return true;
  }

  /** A finger went down on no control. Only one finger turns the camera; a second is ignored. */
  lookDown(pointer: number, x: number, y: number, now: number): boolean {
    if (!this.layout.look || this.looking !== null || this.owner.has(pointer)) return false;
    this.looking = pointer;
    this.owner.set(pointer, { kind: "look", x0: x, y0: y, x, y, t0: now, far: false });
    return true;
  }

  move(pointer: number, x: number, y: number) {
    const o = this.owner.get(pointer);
    if (!o) return;
    if (o.kind === "stick") {
      const s = this.sticks.get(o.id)!;
      const v = stickVector(x - s.state.ox, y - s.state.oy, s.spec.radius, s.spec.dead);
      const changed = v.x !== s.state.x || v.y !== s.state.y;
      s.state = { active: true, ox: s.state.ox, oy: s.state.oy, ...v };
      if (changed) { this.sink.stick?.(o.id, v.x, v.y); this.sync(); }
    } else if (o.kind === "look") {
      const dx = x - o.x, dy = y - o.y;
      o.x = x; o.y = y;
      if (Math.hypot(x - o.x0, y - o.y0) > TAP_PX) o.far = true;
      if (dx !== 0 || dy !== 0) this.sink.look(dx, dy);
    }
  }

  /** The finger was lifted, or the browser cancelled the touch. */
  up(pointer: number, now: number, cancelled = false) {
    const o = this.owner.get(pointer);
    if (!o) return;
    this.owner.delete(pointer);
    if (o.kind === "stick") {
      const s = this.sticks.get(o.id)!;
      const moved = s.state.x !== 0 || s.state.y !== 0;
      s.pointer = null;
      s.state = { active: false, ox: 0, oy: 0, dx: 0, dy: 0, x: 0, y: 0 };
      if (moved) this.sink.stick?.(o.id, 0, 0);
      this.sync();
    } else if (o.kind === "button") {
      this.buttons.get(o.id)!.pointers.delete(pointer);
      this.sync();
    } else {
      this.looking = null;
      this.sink.lookEnd();
      const tap = this.layout.look?.tapKey;
      if (tap !== undefined && !cancelled && !o.far && now - o.t0 <= TAP_MS) { this.sink.key(tap, true); this.sink.key(tap, false); }
    }
  }

  /** Focus was lost: forget every finger and let go of everything. */
  release() {
    const looking = this.looking !== null;
    this.owner.clear();
    this.looking = null;
    for (const [id, s] of this.sticks) {
      const moved = s.state.x !== 0 || s.state.y !== 0;
      s.pointer = null;
      s.state = { active: false, ox: 0, oy: 0, dx: 0, dy: 0, x: 0, y: 0 };
      if (moved) this.sink.stick?.(id, 0, 0);
    }
    for (const b of this.buttons.values()) b.pointers.clear();
    this.sync();
    if (looking) this.sink.lookEnd();
  }

  stick(id: string): StickState { return this.sticks.get(id)!.state; }
  pressed(id: string): boolean { return this.buttons.get(id)!.pointers.size > 0; }

  // Keys are held by the pad as a whole, so a stick and a button that map to the same key do not release each other.
  private sync() {
    const wanted = new Set<number>();
    for (const s of this.sticks.values()) if (s.spec.keys) for (const k of vectorKeys(s.state.x, s.state.y, s.spec.keys)) wanted.add(k);
    for (const b of this.buttons.values()) if (b.pointers.size > 0) wanted.add(b.spec.key);
    for (const k of [...this.held]) if (!wanted.has(k)) { this.held.delete(k); this.sink.key(k, false); }
    for (const k of wanted) if (!this.held.has(k)) { this.held.add(k); this.sink.key(k, true); }
  }
}
