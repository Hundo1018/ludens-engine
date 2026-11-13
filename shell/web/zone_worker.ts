// A zone of the world in a Web Worker: its own instance of zone.wasm (app/zone_main.mojo), stepped at a fixed 60 Hz,
// independent of the page's frame rate and of the other zones. No shared memory: each tick's item array is copied out
// of wasm memory and posted as a transferable buffer, so this works on a host without COOP/COEP.
//
// Messages in:  { type: "start", n, seed, hz? }   create the zone and start ticking
//               { type: "run", ticks }            step exactly `ticks` and reply once (deterministic; no timer)
//               { type: "blob", floats, count }   post `count` buffers of `floats` f32: the cost of the transfer alone
//               { type: "stop" }
// Messages out: { type: "ready", memoryBytes, loadMs }
//               { type: "items", tick, items: Float32Array, tickMs, sentAt, memoryBytes }   after every tick
//               { type: "blob", items: Float32Array, sentAt }
//               { type: "ran", ticks, hash: string, tickMs, memoryBytes }      reply to "run"
//               { type: "error", message }
import { instantiate } from "./host.mjs";

type Rt = { exports: any; f32(ptr: bigint, count: number): Float32Array; memory: WebAssembly.Memory };
const post = (msg: unknown, transfer: Transferable[] = []) => (self as any).postMessage(msg, transfer);
let rt: Rt | null = null;
let zone = 0n;
let timer: ReturnType<typeof setInterval> | null = null;

async function load(): Promise<Rt> {
  if (rt) return rt;
  const bytes = await (await fetch("./zone.wasm")).arrayBuffer();
  rt = (await instantiate(bytes, {})) as Rt;
  return rt;
}

function step(r: Rt, ticks: number): { items: Float32Array; ms: number } {
  const t0 = performance.now();
  if (r.exports.app_zone_tick(zone, ticks) !== 0) throw new Error("app_zone_tick failed");
  const ms = performance.now() - t0;
  // slice(): the view dies with the next call into wasm, and the copy is what gets transferred
  const items = r.f32(r.exports.app_zone_items_ptr(zone), r.exports.app_zone_items_len(zone)).slice();
  return { items, ms };
}

self.onmessage = async (e: MessageEvent) => {
  try {
    const m = e.data;
    if (m.type === "start" || m.type === "run") {
      const t0 = performance.now();
      const r = await load();
      if (zone === 0n) {
        zone = r.exports.app_zone_create(m.n, m.seed);
        if (zone === 0n) throw new Error("app_zone_create failed");
        post({ type: "ready", memoryBytes: r.memory.buffer.byteLength, loadMs: performance.now() - t0 });
      }
      if (m.type === "run") {
        const { ms } = step(r, m.ticks);
        post({ type: "ran", ticks: Number(r.exports.app_zone_ticks(zone)), hash: String(BigInt.asUintN(64, r.exports.app_zone_hash(zone))),
               tickMs: ms / m.ticks, memoryBytes: r.memory.buffer.byteLength });
        return;
      }
      if (timer !== null) return;
      const period = 1000 / (m.hz ?? 60);
      // Fixed step against the clock: a tick that runs long is followed by as many as are due, up to 4, then time is
      // dropped (the zone runs slow and reports it) so a worker that cannot keep up does not fall ever further behind.
      let next = performance.now() + period;
      timer = setInterval(() => {
        try {
          let due = 0;
          const now = performance.now();
          while (now >= next && due < 4) { due++; next += period; }
          if (now >= next) next = now + period;
          if (due === 0) return;
          const { items, ms } = step(r, due);
          post({ type: "items", tick: Number(r.exports.app_zone_ticks(zone)), items, tickMs: ms / due, sentAt: performance.timeOrigin + performance.now(),
                 memoryBytes: r.memory.buffer.byteLength },
               [items.buffer]);
        } catch (err) { post({ type: "error", message: String(err) }); }
      }, 4);
    } else if (m.type === "blob") {
      for (let i = 0; i < m.count; i++) {
        const items = new Float32Array(m.floats).fill(i);
        post({ type: "blob", items, sentAt: performance.timeOrigin + performance.now() }, [items.buffer]);
        await new Promise((r) => setTimeout(r, 5));
      }
      post({ type: "blob-done" });
    } else if (m.type === "stop") {
      if (timer !== null) clearInterval(timer);
      timer = null;
    }
  } catch (err) { post({ type: "error", message: String(err) }); }
};
