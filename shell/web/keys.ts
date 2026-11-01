// DOM -> GLFW key codes; table taken from wgpu-mojo web/wgpu_host.mjs.
const KEYS: Record<string, number> = {
  Space: 32, Escape: 256, Enter: 257, Tab: 258, Backspace: 259,
  ArrowRight: 262, ArrowLeft: 263, ArrowDown: 264, ArrowUp: 265,
  ShiftLeft: 340, ControlLeft: 341, AltLeft: 342,
};

export function keyCode(code: string): number {
  if (code in KEYS) return KEYS[code];
  if (/^Key[A-Z]$/.test(code)) return code.charCodeAt(3);
  if (/^Digit[0-9]$/.test(code)) return code.charCodeAt(5);
  return -1;
}

export const BUTTONS = [0, 2, 1]; // DOM left/middle/right -> GLFW
export const EV = { KEY: 1, MOUSE_BUTTON: 2, CURSOR_POS: 3, SCROLL: 4 } as const;
export const ACTION = { UP: 0, DOWN: 1, REPEAT: 2 } as const;
