// net_* imports (B5) without a wasm module: a fake WebSocket feeds packets, createImports(rt) is called with a fake
// runtime. What it checks is the head-of-queue rule of net_poll: a packet larger than `cap` is dropped and counted,
// and the packets behind it still arrive.
// usage: node tests/test_net.mjs
import { connect, createImports, status } from "../shell/web/net_host.mjs";

let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };

let socket;
globalThis.WebSocket = class { constructor(url) { socket = this; this.url = url; this.readyState = 0; } send() {} };
connect("ws://test.invalid/");
const memory = new Uint8Array(1 << 17);
const rt = { bytes: (p, n) => memory.subarray(Number(p), Number(p) + Number(n)), put: (p, d) => memory.set(d, Number(p)) };
const { net_poll } = createImports(rt).env;
const deliver = (bytes) => socket.onmessage({ data: bytes.buffer });
const CAP = 65536;

check(net_poll(0, CAP) === 0n, "no packet: 0");
deliver(new Uint8Array(CAP + 1).fill(7));    // 65 KB + 1
deliver(Uint8Array.from([9, 8, 7, 6, 5, 4, 3, 2, 1, 0]));
check(status.received === 2 && status.dropped === 0, "two packets received, none dropped yet");
check(net_poll(0, CAP) === -1n, "the oversized packet is answered with -1 once");
check(status.dropped === 1, "...and counted in status.dropped");
const n = net_poll(0, CAP);
check(n === 10n && memory[0] === 9 && memory[9] === 0, "the next poll returns the 10-byte packet behind it");
check(net_poll(0, CAP) === 0n, "then the queue is empty");
deliver(new Uint8Array(CAP).fill(1));
check(net_poll(0, CAP) === BigInt(CAP), "a packet of exactly cap bytes is delivered, not dropped");
check(status.dropped === 1, "dropped stays 1");

console.log(`test_net: ${passed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
