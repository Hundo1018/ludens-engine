// What several wasm modules in Web Workers cost, measured in the page (scripts/multi_wasm_probe.py runs it headless).
//   ?n=<bodies per zone>;live=<bodies per zone in the timed part>;expect=<hash of seed 0>,<seed 1>,...
//   (";" between parameters: the DevTools /json/new endpoint that opens the page cuts the URL at "&")
// 1. Determinism: each worker runs 120 ticks with no timer and must report the hash the native build printed.
// 2. For 1, 2, 3 and 4 workers ticking at 60 Hz for 3 s each: ticks a second per worker, median and worst tick time,
//    how long an item buffer takes from the worker's postMessage to the page's handler, the page's own frame times
//    while the workers run, and each module's linear memory.
// 3. The transfer alone: 50 buffers of 80 000 f32 (10 000 items) from one idle worker.
// Verdict in document.title (PASS / FAIL: why), numbers as one JSON line in #log.
const q = new URLSearchParams(location.search.slice(1).split(";").join("&"));
const N = Number(q.get("n") ?? 1000);
const LIVE = Number(q.get("live") ?? N);
const EXPECT = (q.get("expect") ?? "").split(",").filter(Boolean);
const log = document.getElementById("log")!;
const median = (v: number[]) => (v.length ? [...v].sort((a, b) => a - b)[v.length >> 1] : 0);
const round = (x: number) => Math.round(x * 1000) / 1000;
const worker = () => new Worker("./zone_worker.js", { type: "module" });

function runOnce(n: number, seed: number, ticks: number): Promise<any> {
  return new Promise((resolve, reject) => {
    const w = worker();
    let ready: any = null;
    w.onmessage = (e) => {
      if (e.data.type === "ready") ready = e.data;
      else if (e.data.type === "ran") { w.terminate(); resolve({ ...e.data, loadMs: ready?.loadMs }); }
      else if (e.data.type === "error") { w.terminate(); reject(new Error(e.data.message)); }
    };
    w.onerror = (e) => reject(new Error("worker: " + e.message));
    w.postMessage({ type: "run", n, seed, ticks });
  });
}

async function live(count: number, n: number, seconds: number) {
  const ws = Array.from({ length: count }, worker);
  const per = ws.map(() => ({ ticks: 0, tickMs: [] as number[], transferMs: [] as number[], floats: 0, memoryBytes: 0 }));
  let failed = "";
  await Promise.all(ws.map((w, i) => new Promise<void>((resolve) => {
    w.onmessage = (e) => {
      const m = e.data;
      if (m.type === "ready") resolve();
      else if (m.type === "items") {
        per[i].ticks = m.tick; per[i].tickMs.push(m.tickMs); per[i].floats = m.items.length; per[i].memoryBytes = m.memoryBytes;
        per[i].transferMs.push(performance.timeOrigin + performance.now() - m.sentAt);
      } else if (m.type === "error") { failed = m.message; resolve(); }
    };
    w.postMessage({ type: "start", n, seed: i });
  })));
  // measure from the moment every zone exists; frames are the page's own requestAnimationFrame gaps meanwhile
  const first = per.map((p) => p.ticks);
  for (const p of per) { p.tickMs.length = 0; p.transferMs.length = 0; }
  const frames: number[] = [];
  let last = performance.now(), stop = false;
  const raf = (t: number) => { frames.push(t - last); last = t; if (!stop) requestAnimationFrame(raf); };
  requestAnimationFrame(raf);
  await new Promise((r) => setTimeout(r, seconds * 1000));
  stop = true;
  for (const w of ws) w.terminate();
  if (failed) throw new Error(failed);
  return {
    workers: count, bodies: n,
    ticksPerSecond: per.map((p, i) => round((p.ticks - first[i]) / seconds)),
    tickMsMedian: per.map((p) => round(median(p.tickMs))),
    tickMsMax: per.map((p) => round(Math.max(0, ...p.tickMs))),
    transferMsMedian: per.map((p) => round(median(p.transferMs))),
    transferMsMax: per.map((p) => round(Math.max(0, ...p.transferMs))),
    floatsPerMessage: per[0].floats,
    memoryMiB: per.map((p) => round(p.memoryBytes / 1048576)),
    pageFrameMsMedian: round(median(frames.slice(1))),
    pageFrameMsMax: round(Math.max(0, ...frames.slice(1))),
  };
}

function blobs(floats: number, count: number): Promise<number[]> {
  return new Promise((resolve, reject) => {
    const w = worker();
    const ms: number[] = [];
    w.onmessage = (e) => {
      if (e.data.type === "blob") { if (e.data.items.length === floats) ms.push(performance.timeOrigin + performance.now() - e.data.sentAt); }
      else if (e.data.type === "blob-done") { w.terminate(); resolve(ms); }
      else if (e.data.type === "error") { w.terminate(); reject(new Error(e.data.message)); }
    };
    w.postMessage({ type: "blob", floats, count });
  });
}

(async () => {
  const out: any = { isolated: crossOriginIsolated, cores: navigator.hardwareConcurrency, hashes: [], live: [] };
  const problems: string[] = [];
  try {
    for (let seed = 0; seed < Math.max(EXPECT.length, 1); seed++) {
      const r = await runOnce(N, seed, 120);
      out.hashes.push({ seed, hash: r.hash, tickMs: round(r.tickMs), loadMs: round(r.loadMs), memoryMiB: round(r.memoryBytes / 1048576) });
      if (EXPECT.length && r.hash !== EXPECT[seed]) problems.push(`seed ${seed}: hash ${r.hash}, native ${EXPECT[seed]}`);
    }
    for (const count of [1, 2, 3, 4]) {
      const r = await live(count, LIVE, 3);
      out.live.push(r);
      if (r.ticksPerSecond.some((t: number) => t <= 0)) problems.push(`${count} workers: a zone did not tick`);
    }
    const b = await blobs(80000, 50);
    out.transfer = { floats: 80000, received: b.length, msMedian: round(median(b)), msMax: round(Math.max(0, ...b)) };
    if (b.length !== 50) problems.push(`only ${b.length} of 50 buffers arrived`);
    if (EXPECT.length === 0) problems.push("no expected hashes were given");
  } catch (e) { problems.push(String(e)); }
  log.textContent = JSON.stringify(out);
  document.title = problems.length ? "FAIL: " + problems.join("; ") : "PASS";
})();
