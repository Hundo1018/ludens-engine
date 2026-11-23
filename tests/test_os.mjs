// os_* imports (ludens-engine #8) driven through a real wasm module (build/os_probe.wasm), with injected backends.
// usage: node test_os.mjs os_probe.wasm <ludens-wasm-rt host.mjs>
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createOsImports, memoryStorage, validPath, KIND_CLIPBOARD, KIND_FILE } from "../shell/web/os_host.mjs";

const [wasm, hostMjs] = process.argv.slice(2);
const { instantiate } = await import(pathToFileURL(hostMjs));
let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const tick = () => new Promise((r) => setTimeout(r, 0));

// fake backends: a clipboard with a text slot, and the in-memory storage
let clip = "";
const clipboard = { writeText: async (t) => { clip = t; }, readText: async () => clip };
const storage = memoryStorage();
let os;
const rt = await instantiate(readFileSync(wasm), { libs: [(r) => (os = createOsImports(r, { clipboard, storage }))] });

const str = (s) => rt.str_in(s); // [ptr, len]
const poll = () => {
  const buf = rt.alloc(4096);
  const n = Number(rt.call("p_poll", buf, 4096n));
  if (n <= 0) return n;
  const b = rt.bytes(buf, n).slice();
  return { kind: b[0], id: new DataView(b.buffer).getUint32(1, true), status: b[5], payload: b.slice(6), n };
};

// clipboard round trip
let [p, l] = str("hello 中文 clipboard");
check(rt.call("p_clip_write", p, l) === 0, "clipboard write is accepted");
await tick();
check(clip === "hello 中文 clipboard", "the text reached the clipboard (UTF-8 intact)");
check(rt.call("p_clip_request") === 0 && poll() === 0, "a read request queues; nothing is there before the promise settles");
await tick();
let pk = poll();
check(pk.kind === KIND_CLIPBOARD && pk.status === 0 && new TextDecoder().decode(pk.payload) === "hello 中文 clipboard", "the clipboard text comes back through os_poll");
check(poll() === 0, "os_poll is empty after the packet is taken");

// file write then read: bytes identical
const data = Uint8Array.from({ length: 1000 }, (_, i) => (i * 7 + 3) & 255);
let [pp, pl] = str("saves/slot1.bin");
const dp = rt.alloc(data.length); rt.put(dp, data);
check(rt.call("p_file_write", pp, pl, dp, BigInt(data.length)) === 0, "file write to saves/slot1.bin is accepted");
await tick();
check(storage.files.has("saves/slot1.bin"), "the file is in the app's storage");
check(rt.call("p_file_request", 77, pp, pl) === 0, "a read request queues");
await tick();
pk = poll();
check(pk.kind === KIND_FILE && pk.id === 77 && pk.status === 0 && pk.payload.length === 1000 && pk.payload.every((v, i) => v === data[i]), "the file comes back byte for byte with the request id");
[pp, pl] = str("saves/none.bin");
rt.call("p_file_request", 78, pp, pl);
await tick();
pk = poll();
check(pk.kind === KIND_FILE && pk.id === 78 && pk.status === 1, "a missing file is reported as not found (status 1)");

// the path rule: nothing outside the app's storage can be named
let refused = 0;
const before = storage.files.size;
for (const bad of ["../x", "/etc/passwd", "a/../b", "a//b", "./a", "a/./b", "", "a\\b", "x".repeat(300), "a\0b", "~/x", "dir/"]) {
  const [bp, bl] = str(bad);
  if (rt.call("p_file_write", bp, bl, dp, 4n) === -1 && rt.call("p_file_request", 1, bp, bl) === -1) refused++;
}
await tick();
check(refused === 12 && storage.files.size === before, "12 paths that leave the app's storage or are malformed are all refused, nothing written");
check(validPath("a/b-c_d.e/f1") && !validPath("a/b/../c"), "validPath agrees on the allowed and the refused form");

// a packet larger than the buffer is dropped and counted; it must not block the packets behind it
const big = new Uint8Array(100); big.fill(5);
const bp2 = rt.alloc(100); rt.put(bp2, big);
[pp, pl] = str("big.bin");
rt.call("p_file_write", pp, pl, bp2, 100n);
const tiny = Uint8Array.from([1, 2, 3, 4]);
const tp = rt.alloc(4); rt.put(tp, tiny);
const [tnp, tnl] = str("tiny.bin");
rt.call("p_file_write", tnp, tnl, tp, 4n);
await tick();
rt.call("p_file_request", 5, pp, pl);      // answer: 106 bytes
rt.call("p_file_request", 6, tnp, tnl);    // answer: 10 bytes
await tick();
const small = rt.alloc(16);
check(os.status.dropped === 0, "nothing dropped so far");
check(rt.call("p_poll", small, 16n) === -1n, "a packet larger than the buffer returns -1 once");
check(os.status.dropped === 1, "...the host counted it (status.dropped)");
const n2 = Number(rt.call("p_poll", small, 16n));
const b2 = rt.bytes(small, n2).slice();
check(n2 === 10 && b2[0] === KIND_FILE && new DataView(b2.buffer).getUint32(1, true) === 6 && b2.slice(6).every((v, i) => v === tiny[i]),
      "...and the next poll returns the packet behind it, not the same -1 again");
check(rt.call("p_poll", small, 16n) === 0n, "the queue is then empty");

// OsCloudSave (app/os_cloud_save.mojo): the CloudSave seam over the file imports. Packet kinds: 19 write ack, 20 read result.
const KIND_SAVE_WRITE = 19, KIND_SAVE_READ = 20;
const cs = rt.call("p_cs_new");
const csPoll = () => {
  const buf = rt.alloc(4096);
  const n = Number(rt.call("p_cs_poll", cs, buf, 4096));
  if (n <= 0) return n;
  const b = rt.bytes(buf, n).slice();
  return { kind: b[0], id: new DataView(b.buffer).getUint32(1, true), status: b[5], payload: b.slice(6), n };
};
const saveBytes = Uint8Array.from({ length: 300 }, (_, i) => (i * 13 + 1) & 255);
const sdp = rt.alloc(saveBytes.length); rt.put(sdp, saveBytes);
let [sp, sl] = str("run/a.0");
check(rt.call("p_cs_write", cs, 31, sp, sl, sdp, BigInt(saveBytes.length)) === 0, "OsCloudSave: write of run/a.0 is queued");
let ack = csPoll();
check(ack.kind === KIND_SAVE_WRITE && ack.id === 31 && ack.status === 0, "OsCloudSave: the ack is KIND_SAVE_WRITE with the request id, made when the write was queued");
await tick();
check(storage.files.has("saves/run/a.0") && storage.files.get("saves/run/a.0").length === 300, "OsCloudSave: the file is saves/run/a.0 in the app's storage, 300 bytes");
check(rt.call("p_cs_read", cs, 32, sp, sl) === 0 && csPoll() === 0, "OsCloudSave: a read queues and nothing is there before the promise settles");
await tick();
let rd = csPoll();
check(rd.kind === KIND_SAVE_READ && rd.id === 32 && rd.status === 0 && rd.payload.length === 300 && rd.payload.every((v, i) => v === saveBytes[i]),
      "OsCloudSave: the read comes back as KIND_SAVE_READ, same id, same 300 bytes");
[sp, sl] = str("run/none.1");
rt.call("p_cs_read", cs, 33, sp, sl);
await tick();
rd = csPoll();
check(rd.kind === KIND_SAVE_READ && rd.id === 33 && rd.status === 1, "OsCloudSave: a missing file is STATUS_NOT_FOUND (1)");
[sp, sl] = str("../x");
check(rt.call("p_cs_write", cs, 34, sp, sl, sdp, 4n) === -3 && rt.call("p_cs_read", cs, 35, sp, sl) === -3, "OsCloudSave: a path that leaves the storage is REQ_INVALID (-3), nothing queued");
check(csPoll() === 0, "OsCloudSave: the queue is empty after the refusals");

// no clipboard (a browser that refuses): the call says so
os = null;
const rt2 = await instantiate(readFileSync(wasm), { libs: [(r) => (os = createOsImports(r, { clipboard: null, storage }))] });
const [q, ql] = rt2.str_in("x");
check(rt2.call("p_clip_write", q, ql) === -1 && rt2.call("p_clip_request") === -1, "without a clipboard both clipboard calls return -1");

console.log(`os: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
