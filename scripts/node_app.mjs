// The one place the node harnesses instantiate build/app.wasm (game_run, game_node, node_smoke, audio_app, tests/test_input):
// the wgpu stubs, miniaudio, net_* and os_* import sets, a stand-in canvas, and the runtime. A module that gains an import
// (os_* for the input profile, #117) is then supplied to every harness at once, not found one failing CI job at a time.
//
//   const { rt, wrt, os } = await bootApp({ wasm, hostMjs, wgpuDir, maDir, storage? })
//
// `storage` is the os_* file storage (default: a fresh in-memory one); pass the same object to a second `bootApp` to model a restart.
// `sourceMap` (the JSON of a wasm source map) maps the frames of a crash report written by `os.crash.capture` (#147).
// `device` replaces the browser objects the os_dev_* imports read (shell/web/device_host.mjs `browserDevice()`), so a test can fake a phone.
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

export async function bootApp({ wasm, hostMjs, wgpuDir, maDir, storage, clipboard = null, device, sourceMap = null }) {
  // No DOM and no WebGPU under node: a stand-in canvas so surface creation has something to bind.
  globalThis.document ??= { querySelector: () => ({ width: 640, height: 480, getContext: () => ({}) }) };
  const load = (p) => import(pathToFileURL(p));
  const { instantiate } = await load(hostMjs);
  const { createImports } = await load(`${wgpuDir}/web/webgpu_host.mjs`);
  const { Runtime } = await load(`${wgpuDir}/web/webgpu_runtime.mjs`);
  const ma = await load(`${maDir}/web/miniaudio_host.mjs`);
  const net = await import(new URL("../shell/web/net_host.mjs", import.meta.url)); // no ?ws: net_send answers -1, net_poll 0
  const { createOsImports } = await import(new URL("../shell/web/os_host.mjs", import.meta.url));
  const json = (p) => JSON.parse(readFileSync(p, "utf8"));
  // wgpu's createImports takes its own handle-table Runtime and returns the flat `env` table.
  const wrt = new Runtime(json(`${wgpuDir}/web/webgpu_layout.json`), json(`${wgpuDir}/scripts/webgpu_enum_strings.json`));
  let os;
  const rt = await instantiate(readFileSync(wasm), {
    libs: [() => ({ env: createImports(wrt) }), ma, net, (r) => (os = createOsImports(r, { clipboard, sourceMap, ...(storage ? { storage } : {}), ...(device ? { device } : {}) }))],
  });
  wrt.attach(rt);
  return { rt, wrt, os };
}
