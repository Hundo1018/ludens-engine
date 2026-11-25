// Crash reports on the web (ludens-engine #147, docs/telemetry.md). The module tells the host where its packed crash
// context lies (os_crash_arm(ptr, len), app/os_crash.mojo); when a call into the module throws, `capture(error)` copies
// those bytes out of linear memory without calling into the module, parses the wasm frames of the error's stack, maps
// them to source lines when a source map was given, and writes the report (the format of platform/crash_report.mojo) to
// the os_* storage at saves/crash/pending. The module reads and sends it on the next launch (CrashUpload). Not armed (the
// player has not opted in, or withdrew): nothing is written.
export const CRASH_PATH = "saves/crash/pending";
const MAGIC = 0x5352434c; // "LCRS"
const FORMAT = 1;
const MAX_REASON = 1024;
const MAX_FRAMES = 64;
const MAX_FRAME_TEXT = 256;

/** The wasm frames of a stack trace, innermost first: { funcIndex, offset, name }. V8 prints
 *  `at name (wasm://wasm/1a2b:wasm-function[12]:0x3f2)`, Firefox `name@wasm://...:wasm-function[12]:0x3f2`. */
export function parseWasmStack(stack) {
  const out = [];
  for (const line of String(stack ?? "").split("\n")) {
    const m = /wasm-function\[(\d+)\]:0x([0-9a-fA-F]+)/.exec(line);
    if (!m) continue;
    let name = "";
    const v8 = /^\s*at\s+(\S+)\s+\(/.exec(line);
    const ff = /^([^@\s]+)@/.exec(line);
    if (v8) name = v8[1];
    else if (ff) name = ff[1];
    if (name.startsWith("wasm://")) name = "";
    out.push({ funcIndex: Number(m[1]), offset: parseInt(m[2], 16), name });
  }
  return out;
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/** A wasm source map (one generated line; a segment's column is a byte offset in the module) as a lookup table. */
export function loadSourceMap(map) {
  const m = typeof map === "string" ? JSON.parse(map) : map;
  const offs = [];
  const where = [];
  const cur = [0, 0, 0, 0];
  for (const seg of m.mappings.split(",")) {
    if (!seg) continue;
    const d = [];
    let v = 0;
    let shift = 0;
    for (const ch of seg) {
      const x = B64.indexOf(ch);
      v += (x & 31) * 2 ** shift;
      if (x & 32) { shift += 5; continue; }
      d.push(v % 2 ? -Math.floor(v / 2) : Math.floor(v / 2));
      v = 0;
      shift = 0;
    }
    for (let i = 0; i < 4 && i < d.length; i++) cur[i] += d[i];
    if (d.length >= 4) { offs.push(cur[0]); where.push({ file: m.sources[cur[1]], line: cur[2] + 1, column: cur[3] + 1 }); }
  }
  return { offs, where };
}

/** The source row at or before `offset`, or null. */
export function lookup(table, offset) {
  let lo = 0;
  let hi = table.offs.length - 1;
  let best = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (table.offs[mid] <= offset) { best = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return best < 0 ? null : table.where[best];
}

function fnv1a64(bytes) {
  let h = 0xcbf29ce484222325n;
  for (const b of bytes) h = ((h ^ BigInt(b)) * 0x100000001b3n) & 0xffffffffffffffffn;
  return h;
}

const enc = new TextEncoder();

function cut(s, limit) {
  let b = enc.encode(String(s ?? ""));
  if (b.length <= limit) return b;
  let end = limit;
  while (end > 0 && (b[end] & 0xc0) === 0x80) end--;
  return b.slice(0, end);
}

/** A whole report: header, `context` (CrashReporter.context() bytes) as it is, reason, frames, checksum. */
export function encodeCrash(context, reason, frames) {
  const parts = [];
  const u = (v, n) => { const a = new Uint8Array(n); let x = BigInt(v); for (let i = 0; i < n; i++) { a[i] = Number(x & 0xffn); x >>= 8n; } parts.push(a); };
  const text = (s, n, limit) => { const b = cut(s, limit); u(b.length, n); parts.push(b); };
  u(MAGIC, 4);
  u(FORMAT, 2);
  u(0, 2);
  parts.push(context);
  text(reason, 2, MAX_REASON);
  const fs = frames.slice(0, MAX_FRAMES);
  u(fs.length, 2);
  for (const f of fs) {
    u(f.funcIndex, 4);
    u(f.offset, 4);
    u(f.line ?? 0, 4);
    u(f.column ?? 0, 4);
    text(f.file ?? "", 2, MAX_FRAME_TEXT);
    text(f.name ?? "", 2, MAX_FRAME_TEXT);
  }
  const n = parts.reduce((s, p) => s + p.length, 0);
  const out = new Uint8Array(n + 8);
  let at = 0;
  for (const p of parts) { out.set(p, at); at += p.length; }
  let h = fnv1a64(out.subarray(0, n));
  for (let i = 0; i < 8; i++) { out[n + i] = Number(h & 0xffn); h >>= 8n; }
  return out;
}

/** The os_crash_arm import and `capture`. `sourceMap`: the map's JSON text or object, or null (frames stay unmapped). */
export function createCrashImports(rt, storage, { sourceMap = null } = {}) {
  const status = { armed: 0, captured: 0, written: 0, unarmed: 0 };
  let ctx = { ptr: 0n, len: 0 };
  const table = sourceMap ? loadSourceMap(sourceMap) : null;
  return {
    status,
    env: {
      os_crash_arm(ptr, len) {
        ctx = { ptr: BigInt(ptr), len: Number(len) };
        if (ctx.len > 0) status.armed++;
        return 0;
      },
    },
    /** Write the report for `error` (a trap or an exception out of a call into the module). Resolves to the report bytes,
     *  or null when not armed. The context is copied before anything else: no call into the module happens here. */
    async capture(error) {
      status.captured++;
      if (ctx.len === 0) { status.unarmed++; return null; }
      const context = rt.bytes(ctx.ptr, ctx.len).slice();
      const frames = parseWasmStack(error?.stack).map((f) => {
        const at = table ? lookup(table, f.offset) : null;
        return at ? { ...f, ...at } : f;
      });
      const reason = `${error?.name ?? "Error"}: ${error?.message ?? String(error)}`;
      const report = encodeCrash(context, reason, frames);
      await storage.write(CRASH_PATH, report);
      status.written++;
      return report;
    },
  };
}
