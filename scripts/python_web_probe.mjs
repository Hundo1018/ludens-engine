// The web half of scripts/python_web_probe.py: the engine's C-ABI as a wasm64 module and CPython (Pyodide, wasm32)
// side by side in one JS realm, Python calling the engine's exports through a JS object.
//
//   node scripts/python_web_probe.mjs <host.mjs> <ludens64.wasm> <pyodide dir> <behaviour.py> [raw]
//
// In a page, import { run } and pass URLs; build/py_probe/index.html (written by the .py) does that.
// Prints one JSON line. Nothing here knows the behaviour: it is the Python source the caller hands in, the same
// text the native half runs under CPython with ctypes.

const now = () => performance.now();

async function sha256Hex(bytes) {
  const d = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  return [...d].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** opts: { hostUrl, wasm (bytes | Response | Promise), pyodideUrl (ends in /), source, ticks, calls, raw } */
export async function run(opts) {
  const out = {};
  const t0 = now();
  const { instantiate } = await import(opts.hostUrl);
  const rt = await instantiate(opts.wasm);
  const e = rt.exports;
  out.engineLoadMs = now() - t0;

  const t1 = now();
  const { loadPyodide } = await import(opts.pyodideUrl + 'pyodide.mjs');
  const py = await loadPyodide({ indexURL: opts.pyodideUrl });
  out.pyodideLoadMs = now() - t1;
  out.pythonVersion = py.runPython('import sys; sys.version.split()[0]');

  // The engine as Python sees it. A wasm64 pointer and an int64 body handle are BigInt in JS; Pyodide hands a
  // Python int back as a Number when it fits in 53 bits, so every handle is converted here, explicitly.
  let w = 0n;
  const u64 = (ptr) => new BigUint64Array(rt.memory.buffer, Number(ptr), 1)[0];
  const scratch = e.mw_alloc(16n, 8n);
  const eng = {
    new_world() {
      if (w) e.ld_world_destroy(w);
      const rc = e.ld_world_create(1 / 60, 0, -9.81, 0, scratch);
      if (rc !== 0) throw new Error('ld_world_create ' + rc);
      w = u64(scratch);
    },
    add_box: (px, py_, pz, hx, hy, hz, mass, fixed) => e.ld_body_add_box(w, px, py_, pz, hx, hy, hz, mass, fixed),
    add_sphere: (px, py_, pz, r, mass, fixed) => e.ld_body_add_sphere(w, px, py_, pz, r, mass, fixed),
    impulse: (b, x, y, z) => e.ld_body_apply_impulse(w, BigInt(b), x, y, z),
    step: (n) => e.ld_world_step_ticks(w, n),
    tick: () => Number(e.ld_world_tick(w)),
    hash() {
      const rc = e.ld_world_hash(w, scratch);
      if (rc !== 0) throw new Error('ld_world_hash ' + rc);
      return u64(scratch).toString(16).padStart(16, '0');
    },
  };
  py.registerJsModule('ludens_host', eng);
  py.runPython(opts.source);
  const g = py.globals;
  const host = py.runPython('import ludens_host; ludens_host');

  const t2 = now();
  out.hashPlain = g.get('run')(host, g.get('system_plain'), opts.ticks);
  out.firstRunMs = now() - t2;
  out.startToFirstHashMs = now() - t0;
  out.hashSin = g.get('run')(host, g.get('system_sin'), opts.ticks);

  // Python -> engine: a Python loop calling one export through the JS object
  eng.new_world();
  out.pyToEngineNs = g.get('bench_calls')(host, opts.calls) * 1e9 / opts.calls;
  // JS -> Python: what a per-tick callback costs when the page drives the loop
  const noop = g.get('noop');
  for (let i = 0; i < 2000; i++) noop(i);
  const t3 = now();
  for (let i = 0; i < opts.calls; i++) noop(i);
  out.jsToPyNs = (now() - t3) * 1e6 / opts.calls;
  // one whole callback as the behaviour does it: JS calls Python, Python calls the engine once
  const ball = g.get('build')(host);
  const system = g.get('system_plain');
  for (let i = 0; i < 2000; i++) system(host, ball, i);
  const t4 = now();
  for (let i = 0; i < opts.calls; i++) system(host, ball, i);
  out.callbackNs = (now() - t4) * 1e6 / opts.calls;
  // the engine alone, for scale: one tick of the 12 body world
  const t5 = now();
  e.ld_world_step_ticks(w, 600);
  out.engineTickUs = (now() - t5) * 1e3 / 600;

  // libm: the same inputs through math.* ; the native half compares these bytes with CPython's
  out.tables = {};
  const tables = g.get('math_tables')(opts.tableSize).toJs({ create_proxies: false });
  for (const [name, bytes] of (tables instanceof Map ? tables : Object.entries(tables))) {
    out.tables[name] = await sha256Hex(bytes);
    if (opts.raw) (out.raw ??= {})[name] = Buffer.from(bytes).toString('base64');
  }
  return out;
}

if (typeof process !== 'undefined' && process.argv[1] && import.meta.url.endsWith(process.argv[1].split('/').pop())) {
  const { readFileSync } = await import('node:fs');
  const { pathToFileURL } = await import('node:url');
  const [hostPath, wasmPath, pyodideDir, sourcePath, raw = ''] = process.argv.slice(2);
  const result = await run({
    hostUrl: pathToFileURL(hostPath).href, wasm: readFileSync(wasmPath),
    pyodideUrl: pyodideDir.endsWith('/') ? pyodideDir : pyodideDir + '/',
    source: readFileSync(sourcePath, 'utf8'), ticks: 600, calls: 200000, tableSize: 20000, raw: raw === 'raw',
  });
  result.runtime = 'node ' + process.version;
  console.log(JSON.stringify(result));
}
