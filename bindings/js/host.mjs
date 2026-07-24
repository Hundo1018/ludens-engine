// ===========================================================================
// Shared HOST implementation of the `host` interface (see wit/ludens.wit).
// Used by BOTH the Node driver (run-node.mjs) and the browser driver (web.mjs).
//
// This is the platform layer the engine core imports: logging, a clock, and a
// renderer sink. In the browser `onDraw` forwards to WebGPU/canvas; in Node it
// just records commands so tests can assert on them. The engine core never
// knows the difference -- that is the whole point of the inversion.
// ===========================================================================
const now = () =>
  (typeof performance !== "undefined" && performance.now
    ? performance.now()
    : Date.now());

// Build the imports object passed to WebAssembly.instantiate.
// `getMemory()` must return the instance's Memory (available after instantiate);
// host.log reads its string straight out of linear memory (the manual ABI that
// the Component Model / jco automates for you at layer B).
export function makeHostImports({ getMemory, onDraw, log = console.log }) {
  const start = now();
  const decoder = new TextDecoder();
  return {
    host: {
      log(ptr, len) {
        const bytes = new Uint8Array(getMemory().buffer, ptr, len);
        log(decoder.decode(bytes));
      },
      now_ms() {
        return now() - start;
      },
      draw_rect(x, y, w, h, rgba) {
        onDraw(x, y, w, h, rgba >>> 0);
      },
    },
  };
}
