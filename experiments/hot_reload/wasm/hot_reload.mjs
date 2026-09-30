// ===========================================================================
// Hot-reload strategies for a wasm engine core whose state lives in linear
// memory. Shared by the Node experiment (hot_reload.test.mjs, bench.mjs) and
// the browser dev loop (web_hot.mjs). No dependencies.
//
//   restart   new instance + engine_init. State is discarded (baseline).
//   memcopy   copy the old instance's whole linear memory into the new one.
//             Needs identical data layout; also copies stale read-only data.
//   memcopy-rw  like memcopy, but leaves the new module's .rodata segment
//             untouched (segment ranges parsed from the binary).
//   snapshot  old.engine_save() -> copy the serialized bytes -> new.engine_load().
//             Layout-independent; needs the module to export save/load.
//   auto      memcopy-rw only when ALL guards pass: __data_end/__heap_base,
//             engine_layout_id() (source struct offsets) and the link-map
//             fingerprint (addresses of writable symbols in the linked binary).
//             Any guard failing or missing -> snapshot.
// ===========================================================================

// ---- minimal wasm binary reader: data segments + their names -------------
function readU32(buf, pos) {
  let result = 0, shift = 0, b;
  do {
    b = buf[pos.i++];
    result |= (b & 0x7f) << shift;
    shift += 7;
  } while (b & 0x80);
  return result >>> 0;
}
function readI32(buf, pos) {
  let result = 0, shift = 0, b;
  do {
    b = buf[pos.i++];
    result |= (b & 0x7f) << shift;
    shift += 7;
  } while (b & 0x80);
  if (shift < 32 && (b & 0x40)) result |= -1 << shift;
  return result;
}
function readName(buf, pos) {
  const n = readU32(buf, pos);
  const s = new TextDecoder().decode(buf.subarray(pos.i, pos.i + n));
  pos.i += n;
  return s;
}

// -> [{ index, offset, size, name }] for active segments of memory 0
export function dataSegments(bytes) {
  const buf = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const pos = { i: 8 };
  const segs = [];
  const names = new Map();
  while (pos.i < buf.length) {
    const id = buf[pos.i++];
    const size = readU32(buf, pos);
    const end = pos.i + size;
    if (id === 11) {
      const count = readU32(buf, pos);
      for (let k = 0; k < count; k++) {
        const flags = readU32(buf, pos);
        if (flags === 1) { // passive: no offset
          const n = readU32(buf, pos);
          pos.i += n;
          continue;
        }
        if (flags === 2) readU32(buf, pos); // memidx
        const op = buf[pos.i++];
        if (op !== 0x41) throw new Error(`unsupported offset expr 0x${op.toString(16)}`);
        const offset = readI32(buf, pos);
        pos.i++; // 0x0b end
        const n = readU32(buf, pos);
        segs.push({ index: k, offset, size: n });
        pos.i += n;
      }
    } else if (id === 0) {
      const secName = readName(buf, pos);
      if (secName === "name") {
        while (pos.i < end) {
          const sub = buf[pos.i++];
          const subSize = readU32(buf, pos);
          const subEnd = pos.i + subSize;
          if (sub === 9) {
            const count = readU32(buf, pos);
            for (let k = 0; k < count; k++) {
              const idx = readU32(buf, pos);
              names.set(idx, readName(buf, pos));
            }
          }
          pos.i = subEnd;
        }
      }
    }
    pos.i = end;
  }
  for (const s of segs) s.name = names.get(s.index) ?? null;
  return segs;
}

// ---- layout fingerprint -----------------------------------------------------
const globalValue = (x, name) => (x[name] instanceof WebAssembly.Global ? x[name].value : null);

export function layoutOf(x) {
  return {
    layoutId: typeof x.engine_layout_id === "function" ? x.engine_layout_id() >>> 0 : null,
    dataEnd: globalValue(x, "__data_end"),
    heapBase: globalValue(x, "__heap_base"),
  };
}

// address-only guard (what a host can check without module cooperation)
export function addressesMatch(a, b) {
  return a.dataEnd === b.dataEnd && a.heapBase === b.heapBase;
}
// module-declared struct layout (offsetof hash compiled into the module)
export function layoutIdMatch(a, b) {
  return a.layoutId !== null && a.layoutId === b.layoutId;
}
// link-map fingerprint (computed at build time, shipped beside the .wasm)
export function mapMatch(fpOld, fpNew) {
  return fpOld != null && fpOld === fpNew;
}
export function transplantSafe(a, b, fpOld, fpNew) {
  return addressesMatch(a, b) && layoutIdMatch(a, b) && mapMatch(fpOld, fpNew);
}

// ---- transfer strategies ----------------------------------------------------
function growTo(memory, bytes) {
  const need = Math.ceil(bytes / 65536) - memory.buffer.byteLength / 65536;
  if (need > 0) memory.grow(need);
}

export function transplantMemory(oldX, newX, { skip = [] } = {}) {
  const src = new Uint8Array(oldX.memory.buffer);
  growTo(newX.memory, src.byteLength);
  const dst = new Uint8Array(newX.memory.buffer);
  // copy [0, len) minus the skipped ranges (sorted, non-overlapping)
  let at = 0;
  for (const { offset, size } of [...skip].sort((p, q) => p.offset - q.offset)) {
    if (offset > at) dst.set(src.subarray(at, offset), at);
    at = Math.max(at, offset + size);
  }
  if (at < src.byteLength) dst.set(src.subarray(at), at);
  return src.byteLength;
}

export function snapshotTransfer(oldX, newX) {
  const n = oldX.engine_save();
  if (n === 0) throw new Error("engine_save: snapshot does not fit");
  const bytes = new Uint8Array(oldX.memory.buffer, oldX.engine_snapshot_ptr(), n);
  new Uint8Array(newX.memory.buffer, newX.engine_snapshot_ptr(), n).set(bytes);
  if (newX.engine_load() !== 1) throw new Error("engine_load rejected snapshot");
  return n;
}

// Swap `oldX` (live exports) for a module built from `newBytes`.
// `instantiate(bytes)` must return new exports wired to the same host imports.
// `fingerprints` = { old, new } link-map fingerprints (see layout_map.py).
// Returns { exports, strategy, transferred, ms: { compile, instantiate, transfer, total } }.
export async function hotSwap(oldX, newBytes, instantiate,
                              { strategy = "auto", capacity, fingerprints = {} } = {}) {
  const t0 = performance.now();
  const module = await WebAssembly.compile(newBytes);
  const t1 = performance.now();
  const newX = await instantiate(module);
  const t2 = performance.now();

  let used = strategy;
  if (strategy === "auto") {
    const safe = transplantSafe(layoutOf(oldX), layoutOf(newX), fingerprints.old, fingerprints.new);
    used = safe ? "memcopy-rw" : "snapshot";
  }
  let transferred = 0;
  switch (used) {
    case "restart":
      newX.engine_init(capacity);
      break;
    case "memcopy":
      transferred = transplantMemory(oldX, newX);
      break;
    case "memcopy-rw": {
      const ro = dataSegments(newBytes).filter((s) => s.name === ".rodata");
      transferred = transplantMemory(oldX, newX, { skip: ro });
      break;
    }
    case "snapshot":
      transferred = snapshotTransfer(oldX, newX);
      break;
    default:
      throw new Error(`unknown strategy ${used}`);
  }
  const t3 = performance.now();
  return {
    exports: newX,
    strategy: used,
    transferred,
    ms: { compile: t1 - t0, instantiate: t2 - t1, transfer: t3 - t2, total: t3 - t0 },
  };
}
