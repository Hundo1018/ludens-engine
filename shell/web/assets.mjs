// Asset loader (ludens-playground step 4): fetch a file, check it against a sha256 pinned in the content manifest,
// and copy it into wasm memory. No DOM, no wasm import: scripts/test_assets.mjs runs it under node.
//
//   loadAsset(url, sha256Hex, { maxBytes })  -> Promise<Uint8Array>   rejects if the status, size or hash is wrong
//   stageAsset(rt, bytes)                    -> { ptr, len, free() }  bytes copied into wasm memory via rt.alloc/put
//
// Two rules the caller cannot turn off: the hash must match (the manifest is the licence record, so a changed file
// is a changed asset), and the size is capped. Assets are data: nothing here runs code from them.

export const MAX_ASSET_BYTES = 64 * 1024 * 1024;

const HEX = /^[0-9a-f]{64}$/;

export function hex(buf) {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(bytes) {
  return hex(await globalThis.crypto.subtle.digest("SHA-256", bytes));
}

export async function loadAsset(url, sha256, { maxBytes = MAX_ASSET_BYTES, fetchImpl = globalThis.fetch } = {}) {
  if (typeof url !== "string" || !/^https?:\/\//.test(url)) throw new Error(`asset url must be http(s): ${url}`);
  if (typeof sha256 !== "string" || !HEX.test(sha256)) throw new Error(`asset sha256 must be 64 lowercase hex digits`);
  if (!Number.isInteger(maxBytes) || maxBytes <= 0 || maxBytes > MAX_ASSET_BYTES) throw new Error(`maxBytes out of range`);
  const res = await fetchImpl(url);
  if (!res.ok) throw new Error(`asset ${url}: HTTP ${res.status}`);
  const declared = Number(res.headers?.get?.("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) throw new Error(`asset ${url}: ${declared} bytes is over the ${maxBytes} cap`);
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (bytes.length > maxBytes) throw new Error(`asset ${url}: ${bytes.length} bytes is over the ${maxBytes} cap`);
  const got = await sha256Hex(bytes);
  if (got !== sha256) throw new Error(`asset ${url}: sha256 ${got} does not match the manifest ${sha256}`);
  return bytes;
}

export function stageAsset(rt, bytes) {
  const ptr = rt.alloc(Math.max(1, bytes.length));
  rt.put(ptr, bytes);
  return { ptr, len: bytes.length, free: () => rt.free(ptr) };
}
