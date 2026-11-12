// Virtual pad kit, view: draws a `PadLayout` over the page and feeds touches to the core (shell/web/vpad.ts).
// DOM elements above the canvas, so nothing the app renders or reads back changes.
//
// The pad stays hidden until the page sees a touch, or the device's main pointer is coarse (a phone), or `force`.
// Controls are placed from the viewport's edges plus the safe-area inset, not from the canvas: in portrait the canvas
// is a strip at the top and the controls sit below it.
import { VirtualPad, type PadLayout, type PadSink, type Placement } from "./vpad.js";

const CSS = `
.vpad{position:fixed;inset:0;pointer-events:none;z-index:10;display:none;
  user-select:none;-webkit-user-select:none;-webkit-touch-callout:none;-webkit-tap-highlight-color:transparent}
.vpad.on{display:block}
.vpad>*{position:absolute;pointer-events:auto;touch-action:none}
.vpad-base{pointer-events:none;border-radius:50%;box-sizing:border-box;border:2px solid rgba(255,255,255,.35);background:rgba(255,255,255,.08)}
.vpad-knob{pointer-events:none;border-radius:50%;background:rgba(255,255,255,.45)}
.vpad-zone.on .vpad-base{border-color:rgba(255,255,255,.6)}
.vpad-btn{border-radius:50%;box-sizing:border-box;border:2px solid rgba(255,255,255,.35);background:rgba(255,255,255,.12);
  color:rgba(255,255,255,.85);font:600 14px system-ui;display:flex;align-items:center;justify-content:center}
.vpad-btn.on{background:rgba(255,255,255,.4)}
`;

function place(el: HTMLElement, at: Placement) {
  for (const side of ["left", "right", "top", "bottom"] as const) {
    const v = at[side];
    if (v !== undefined) el.style[side] = `calc(env(safe-area-inset-${side}, 0px) + ${v}px)`;
  }
}

export interface PadView {
  pad: VirtualPad;
  shown(): boolean;
  show(): void;
  /** Focus was lost: let go of everything and redraw the controls at rest. */
  release(): void;
}

export function mountVirtualPad(canvas: HTMLCanvasElement, layout: PadLayout, sink: PadSink, force = false): PadView {
  const pad = new VirtualPad(layout, sink);
  const style = document.createElement("style");
  style.textContent = CSS;
  document.head.append(style);
  const root = document.createElement("div");
  root.className = "vpad";
  root.addEventListener("contextmenu", (e) => e.preventDefault());
  const redraw: (() => void)[] = [];

  for (const spec of layout.sticks) {
    const r = spec.radius, knobR = Math.round(r * 0.45);
    // The zone is the area that takes the finger; it hangs from the same corner as the stick's resting place.
    const zone = document.createElement("div");
    zone.className = "vpad-zone";
    zone.dataset.stick = spec.id;
    zone.style.width = spec.zone?.width ?? "46vw";
    zone.style.height = spec.zone?.height ?? "60vh";
    place(zone, { left: spec.at.left === undefined ? undefined : 0, right: spec.at.right === undefined ? undefined : 0,
                  top: spec.at.top === undefined ? undefined : 0, bottom: spec.at.bottom === undefined ? undefined : 0 });
    const base = document.createElement("div");
    base.className = "vpad-base";
    base.style.cssText = `position:absolute;width:${2 * r}px;height:${2 * r}px`;
    const knob = document.createElement("div");
    knob.className = "vpad-knob";
    knob.style.cssText = `position:absolute;width:${2 * knobR}px;height:${2 * knobR}px;left:${r - knobR - 2}px;top:${r - knobR - 2}px`;
    base.append(knob);
    zone.append(base);
    root.append(zone);
    const draw = () => {
      const s = pad.stick(spec.id);
      zone.classList.toggle("on", s.active);
      if (s.active) {
        const box = zone.getBoundingClientRect();
        base.style.left = `${s.ox - box.left - r}px`; base.style.top = `${s.oy - box.top - r}px`;
        base.style.right = base.style.bottom = "";
      } else {
        base.style.left = base.style.top = base.style.right = base.style.bottom = "";
        for (const side of ["left", "right", "top", "bottom"] as const) if (spec.at[side] !== undefined) base.style[side] = `${spec.at[side]}px`;
      }
      knob.style.transform = `translate(${s.dx}px, ${s.dy}px)`;
    };
    redraw.push(draw);
    draw();
    zone.addEventListener("pointerdown", (e) => {
      if (!pad.stickDown(spec.id, e.pointerId, e.clientX, e.clientY)) return;
      zone.setPointerCapture(e.pointerId);
      e.preventDefault();
      draw();
    });
    zone.addEventListener("pointermove", (e) => { pad.move(e.pointerId, e.clientX, e.clientY); draw(); });
    const up = (e: PointerEvent) => { pad.up(e.pointerId, e.timeStamp, e.type === "pointercancel"); draw(); };
    zone.addEventListener("pointerup", up);
    zone.addEventListener("pointercancel", up);
  }

  for (const spec of layout.buttons) {
    const b = document.createElement("div");
    b.className = "vpad-btn";
    b.dataset.button = spec.id;
    b.textContent = spec.label;
    b.style.width = b.style.height = `${spec.size}px`;
    place(b, spec.at);
    root.append(b);
    const draw = () => b.classList.toggle("on", pad.pressed(spec.id));
    redraw.push(draw);
    b.addEventListener("pointerdown", (e) => {
      if (!pad.buttonDown(spec.id, e.pointerId)) return;
      b.setPointerCapture(e.pointerId);
      e.preventDefault();
      draw();
    });
    const up = (e: PointerEvent) => { pad.up(e.pointerId, e.timeStamp, e.type === "pointercancel"); draw(); };
    b.addEventListener("pointerup", up);
    b.addEventListener("pointercancel", up);
  }
  document.body.append(root);

  // A touch on the canvas itself, outside every control, turns the camera.
  const isTouch = (e: PointerEvent) => e.pointerType === "touch";
  canvas.addEventListener("pointerdown", (e) => {
    if (isTouch(e) && pad.lookDown(e.pointerId, e.clientX, e.clientY, e.timeStamp)) canvas.setPointerCapture(e.pointerId);
  });
  canvas.addEventListener("pointermove", (e) => { if (isTouch(e)) pad.move(e.pointerId, e.clientX, e.clientY); });
  const lookUp = (e: PointerEvent) => { if (isTouch(e)) pad.up(e.pointerId, e.timeStamp, e.type === "pointercancel"); };
  canvas.addEventListener("pointerup", lookUp);
  canvas.addEventListener("pointercancel", lookUp);

  let shown = false;
  const show = () => {
    if (shown) return;
    shown = true;
    root.classList.add("on");
    document.documentElement.classList.add("touch");
  };
  if (force || matchMedia("(pointer: coarse)").matches) show();
  addEventListener("pointerdown", (e) => { if (isTouch(e)) show(); }, { capture: true });

  return { pad, shown: () => shown, show, release: () => { pad.release(); for (const d of redraw) d(); } };
}
