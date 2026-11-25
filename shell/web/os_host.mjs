import { createCrashImports } from "./crash_host.mjs";
import { browserDevice, createDeviceImports } from "./device_host.mjs";

// os_* imports (ludens-engine #8): the platform services a game or an editor needs, as generic imports.
//   os_clipboard_write(ptr, len)            -> 0 queued, -1 refused
//   os_clipboard_read_request()             -> 0 queued
//   os_file_write(path_ptr, path_len, data_ptr, data_len) -> 0 queued, -1 invalid path / too large
//   os_file_read_request(id, path_ptr, path_len)          -> 0 queued, -1 invalid path
//   os_poll(buf, cap)                       -> bytes of the next result copied to buf, 0 if none, -1 if the next one was larger
//                                              than cap (it is dropped and counted in status.dropped; poll again for the next)
// A result packet is [kind u8][id u32 LE][status u8][payload]: kind 1 = clipboard text (id 0), kind 2 = file read
// (id of the request; status 0 ok, 1 not found, 2 error). Asynchronous work never calls back into wasm: its result
// is queued and the game takes it with os_poll inside a frame (ludens-wasm-rt's re-entry rule).
// os_crash_arm(ptr, len) and `crash.capture(error)` (#147) are in crash_host.mjs; the report goes to the same storage.
// The device imports (os_dev_*: haptics, motion, screen, pointer lock, camera, microphone; #135) are in device_host.mjs, and use the same os_poll queue.
// What it cannot do, on purpose (Play policy, ludens-engine #23): load code, run commands, install anything, or touch a
// path outside the app's own storage. File paths are relative, `/`-separated, with no `.` / `..` / empty segment.
export const MAX_FILE_BYTES = 64 * 1024 * 1024;
export const MAX_CLIPBOARD_BYTES = 1024 * 1024;
export const KIND_CLIPBOARD = 1;
export const KIND_FILE = 2;

export function validPath(p) {
  if (typeof p !== "string" || p.length === 0 || p.length > 256) return false;
  if (!/^[A-Za-z0-9._\- /]+$/.test(p)) return false;
  if (p.startsWith("/") || p.endsWith("/")) return false;
  return p.split("/").every((s) => s.length > 0 && s !== "." && s !== "..");
}

export function memoryStorage() {
  const files = new Map();
  return { files, async write(path, bytes) { files.set(path, bytes.slice()); }, async read(path) { return files.has(path) ? files.get(path).slice() : null; } };
}

/** The browser's origin-private file system. Not exercised under node (no OPFS there); the node test uses memoryStorage. */
export function opfsStorage() {
  const dirOf = async (path, create) => {
    let dir = await navigator.storage.getDirectory();
    const parts = path.split("/");
    for (const part of parts.slice(0, -1)) dir = await dir.getDirectoryHandle(part, { create });
    return [dir, parts[parts.length - 1]];
  };
  return {
    async write(path, bytes) {
      const [dir, name] = await dirOf(path, true);
      const w = await (await dir.getFileHandle(name, { create: true })).createWritable();
      await w.write(bytes);
      await w.close();
    },
    async read(path) {
      try {
        const [dir, name] = await dirOf(path, false);
        return new Uint8Array(await (await (await dir.getFileHandle(name)).getFile()).arrayBuffer());
      } catch { return null; }
    },
  };
}

export function createOsImports(rt, { clipboard = globalThis.navigator?.clipboard, storage = memoryStorage(), device = browserDevice(), sourceMap = null } = {}) {
  const inbox = [];
  const status = { clipboardWrites: 0, fileWrites: 0, fileReads: 0, refused: 0, dropped: 0 };
  const packet = (kind, id, st, payload) => {
    const out = new Uint8Array(6 + payload.length);
    out[0] = kind;
    new DataView(out.buffer).setUint32(1, id >>> 0, true);
    out[5] = st;
    out.set(payload, 6);
    return out;
  };
  const dev = createDeviceImports(rt, (p) => inbox.push(p), device); // os_dev_*: shell/web/device_host.mjs
  const crash = createCrashImports(rt, storage, { sourceMap }); // os_crash_arm: shell/web/crash_host.mjs
  return {
    status,
    device: dev.status,
    crash,
    env: {
      ...dev.env,
      ...crash.env,
      os_clipboard_write(ptr, len) {
        if (!clipboard || Number(len) > MAX_CLIPBOARD_BYTES) { status.refused++; return -1; }
        const text = rt.str(ptr, len);
        status.clipboardWrites++;
        clipboard.writeText(text).catch(() => {});
        return 0;
      },
      os_clipboard_read_request() {
        if (!clipboard) return -1;
        clipboard.readText().then(
          (t) => inbox.push(packet(KIND_CLIPBOARD, 0, 0, new TextEncoder().encode(t))),
          () => inbox.push(packet(KIND_CLIPBOARD, 0, 2, new Uint8Array(0))),
        );
        return 0;
      },
      os_file_write(pp, pl, dp, dl) {
        const path = rt.str(pp, pl);
        if (!validPath(path) || Number(dl) > MAX_FILE_BYTES) { status.refused++; return -1; }
        const data = rt.bytes(dp, dl).slice(); // copy: wasm memory may move
        status.fileWrites++;
        storage.write(path, data).catch(() => {});
        return 0;
      },
      os_file_read_request(id, pp, pl) {
        const path = rt.str(pp, pl);
        if (!validPath(path)) { status.refused++; return -1; }
        const rid = Number(id);
        status.fileReads++;
        storage.read(path).then(
          (b) => inbox.push(b ? packet(KIND_FILE, rid, 0, b) : packet(KIND_FILE, rid, 1, new Uint8Array(0))),
          () => inbox.push(packet(KIND_FILE, rid, 2, new Uint8Array(0))),
        );
        return 0;
      },
      os_poll(buf, cap) {
        const next = inbox[0];
        if (!next) return 0n;
        if (next.length > Number(cap)) {
          // Same rule as net_poll: a result larger than cap is dropped and counted, not left to block the queue.
          inbox.shift();
          status.dropped++;
          return -1n;
        }
        inbox.shift();
        rt.put(buf, next);
        return BigInt(next.length);
      },
    },
  };
}
