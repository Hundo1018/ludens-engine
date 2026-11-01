// net_* imports (B5): a WebSocket behind net_send / net_poll. Binary packets, one WebSocket message each.
// The socket opens from boot() when ?ws=<url> is present; net_send before the socket is open queues.
let ws = null;
const out = [];  // packets sent before the socket opened
const inbox = []; // received packets, Uint8Array each
export const status = { opened: false, sent: 0, received: 0, error: "" };

export function connect(url) {
  ws = new WebSocket(url);
  ws.binaryType = "arraybuffer";
  ws.onopen = () => { status.opened = true; for (const p of out.splice(0)) ws.send(p); };
  ws.onmessage = (e) => { status.received++; inbox.push(new Uint8Array(e.data)); };
  ws.onerror = () => { status.error = "websocket error"; };
}

export function createImports(rt) {
  return {
    env: {
      net_send(ptr, len) {
        if (!ws || ws.readyState > 1) return -1;
        const data = rt.bytes(ptr, len).slice(); // copy: wasm memory may move
        status.sent++;
        if (ws.readyState === 1) ws.send(data); else out.push(data);
        return 0;
      },
      net_poll(buf, cap) {
        const next = inbox[0];
        if (!next) return 0n;
        if (next.length > Number(cap)) return -1n;
        inbox.shift();
        rt.put(buf, next);
        return BigInt(next.length);
      },
    },
  };
}
