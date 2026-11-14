// Asset loader (shell/web/assets.mjs) under node: a served file loads when its sha256 matches, and every other case is
// refused. usage: node scripts/test_assets.mjs
import http from "node:http";
import { loadAsset, stageAsset, sha256Hex, MAX_ASSET_BYTES } from "../shell/web/assets.mjs";

let passed = 0, failed = 0;
const ok = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };

const body = new Uint8Array(4096);
for (let i = 0; i < body.length; i++) body[i] = (i * 31 + 7) & 0xff;
const goodHash = await sha256Hex(body);
const wrongHash = "0".repeat(64);

const server = http.createServer((req, res) => {
  if (req.url === "/asset.bin") { res.writeHead(200, { "content-length": body.length }); res.end(Buffer.from(body)); return; }
  if (req.url === "/big.bin") { res.writeHead(200, { "content-length": body.length }); res.end(Buffer.from(body)); return; }
  if (req.url === "/unknown.bin") { res.writeHead(200); res.end(Buffer.from(body)); return; }
  res.writeHead(404); res.end("nope");
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}`;

const expectReject = async (p, pattern) => {
  try { await p; return false; } catch (e) { return pattern.test(String(e.message)); }
};

// the loader
const got = await loadAsset(`${base}/asset.bin`, goodHash);
ok(got.length === body.length && got.every((v, i) => v === body[i]), "a file with the manifest's hash loads and is byte-identical");
ok(await expectReject(loadAsset(`${base}/asset.bin`, wrongHash), /does not match the manifest/), "a file whose hash differs from the manifest is refused");
ok(await expectReject(loadAsset(`${base}/missing.bin`, goodHash), /HTTP 404/), "a 404 is refused");
ok(await expectReject(loadAsset(`${base}/big.bin`, goodHash, { maxBytes: 1000 }), /over the 1000 cap/), "a file over maxBytes is refused by its content-length");
ok(await expectReject(loadAsset(`${base}/unknown.bin`, goodHash, { maxBytes: 1000 }), /over the 1000 cap/), "a file over maxBytes with no content-length is refused after reading");
ok(await expectReject(loadAsset("file:///etc/passwd", goodHash), /must be http/), "a non-http url is refused");
ok(await expectReject(loadAsset(`${base}/asset.bin`, goodHash.toUpperCase()), /64 lowercase hex/), "an uppercase hash is refused (the manifest uses lowercase)");
ok(await expectReject(loadAsset(`${base}/asset.bin`, goodHash, { maxBytes: MAX_ASSET_BYTES + 1 }), /maxBytes out of range/), "a maxBytes above the global cap is refused");

// the staging copy: a fake rt that records the calls
const calls = [];
const rt = {
  alloc(n) { calls.push(["alloc", n]); return 4242; },
  put(p, data) { calls.push(["put", p, data.length]); },
  free(p) { calls.push(["free", p]); },
};
const staged = stageAsset(rt, body);
ok(staged.ptr === 4242 && staged.len === body.length, "stageAsset reports the pointer and the length");
ok(calls[0][0] === "alloc" && calls[0][1] === body.length && calls[1][0] === "put" && calls[1][2] === body.length, "stageAsset allocates the length and copies all of it");
staged.free();
ok(calls[calls.length - 1][0] === "free" && calls[calls.length - 1][1] === 4242, "free releases the same pointer");
const empty = stageAsset(rt, new Uint8Array(0));
ok(calls.some((c) => c[0] === "alloc" && c[1] === 1), "an empty asset still allocates one byte, so the pointer is valid");
empty.free();

server.close();
console.log(`test_assets: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
