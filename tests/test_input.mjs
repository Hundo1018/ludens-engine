// The input action map end to end through the wasm64 app under node (ludens-engine #117), no WebGPU:
// analog axes, gamepad and on-screen pad events, rebinding with conflicts, the profile saved through os_file_write, and a second
// instance of the module started on the same storage that restores it through os_file_read_request / os_poll.
// usage: node --experimental-strip-types tests/test_input.mjs build/app.wasm <ludens-wasm-rt host.mjs> <wgpu-mojo dir> <miniaudio-mojo dir>
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

globalThis.document ??= { querySelector: () => ({ width: 640, height: 480, getContext: () => ({}) }) };
const [wasm, hostMjs, wgpuDir, maDir] = process.argv.slice(2);
const load = (p) => import(pathToFileURL(p));
const { instantiate } = await load(hostMjs);
const { createImports } = await load(`${wgpuDir}/web/webgpu_host.mjs`);
const { Runtime } = await load(`${wgpuDir}/web/webgpu_runtime.mjs`);
const ma = await load(`${maDir}/web/miniaudio_host.mjs`);
const net = await import(new URL("../shell/web/net_host.mjs", import.meta.url));
const { createOsImports, memoryStorage } = await import(new URL("../shell/web/os_host.mjs", import.meta.url));
const { createGameHook } = await import(new URL("../shell/web/game_hook.mjs", import.meta.url));
const { keyCode } = await import(new URL("../shell/web/keys.ts", import.meta.url));
const json = (p) => JSON.parse(readFileSync(p, "utf8"));

let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const tick = () => new Promise((r) => setTimeout(r, 0));
const storage = memoryStorage(); // survives the "restart": the page's origin-private file system in a browser

/** A fresh module instance (a restart) over the shared storage, the game running, its hook. */
async function boot() {
  const wrt = new Runtime(json(`${wgpuDir}/web/webgpu_layout.json`), json(`${wgpuDir}/scripts/webgpu_enum_strings.json`));
  const rt = await instantiate(readFileSync(wasm), { libs: [() => ({ env: createImports(wrt) }), ma, net, (r) => createOsImports(r, { storage })] });
  wrt.attach(rt);
  const [ptr, len] = rt.str_in("#canvas");
  const app = rt.call("app_init", ptr, len, 640, 480);
  if (rt.call("app_set_mode", app, 1) !== 0) throw new Error("app_set_mode failed");
  const game = createGameHook({ rt, app, keyCode });
  game.configure(0, "bare");
  return game;
}
const run = async (game, n) => { for (let i = 0; i < n; i++) { game.step(1, false); await tick(); } }; // a tick lets os results queue between frames
const pos = (game) => game.state().ball.pos;
const moved = async (game, hold, n = 30) => { // the ball's displacement after n frames of `hold`, from a fresh start
  game.configure(0, "bare");
  const p0 = pos(game);
  hold();
  await run(game, n);
  game.releaseAll();
  game.axis(0, 0, 0); game.axis(0, 1, 0);
  const p1 = pos(game);
  return [p1[0] - p0[0], p1[2] - p0[2]]; // x right, z toward the camera (forward is -z at yaw 0)
};

let game = await boot();
await run(game, 3);
check(game.prompt("jump", "keyboard") === "Space" && game.prompt("jump", "gamepad") === "A" && game.prompt("move.up", "keyboard") === "W", "prompt(): Space, A and W by default");
check(game.prompt("jump", "mouse") === "", "prompt(): no mouse binding gives an empty string");

// analog axes: the stick pushed 60 % right moves at (0.6 - 0.2) / 0.8 = 50 % of full speed; 15 % (inside the dead zone) does not move
const full = await moved(game, () => game.hold("KeyD"));
const half = await moved(game, () => game.axis(0, 0, 0.6));
check(full[0] > 0.5 && Math.abs(half[0] / full[0] - 0.5) < 0.03, `stick x = 0.6 moves at ${(half[0] / full[0]).toFixed(3)} of the key's distance (0.5 expected): ${half[0].toFixed(3)} vs ${full[0].toFixed(3)} m`);
const drift = await moved(game, () => { game.axis(0, 0, 0.1); game.axis(0, 1, 0.1); });
check(Math.hypot(...drift) < 1e-6, `a stick resting at (0.1, 0.1) moves nothing: ${drift.map((v) => v.toFixed(6)).join(", ")}`);
const up = await moved(game, () => game.axis(0, 1, -1));
check(up[1] < -0.5 && Math.abs(up[0]) < 1e-6, `stick up (y = -1) moves forward (-z): ${up.map((v) => v.toFixed(3)).join(", ")}`);
const vpad = await moved(game, () => game.axis(3, 0, 1));
check(Math.abs(vpad[0] - full[0]) < 0.02, "the on-screen pad's stick (device 3) moves like the key");
const dpad = await moved(game, () => game.padButton(0, 15, true));
check(Math.abs(dpad[0] - full[0]) < 0.02, "gamepad d-pad right (button 15) moves like the key");
game.padButton(0, 15, false);

// a gamepad button jumps; the jump count is in the state
game.configure(0, "bare");
await run(game, 60);
const j0 = game.state().jumps;
game.padButton(0, 0, true); await run(game, 1); game.padButton(0, 0, false);
await run(game, 5);
check(game.state().jumps === j0 + 1, "gamepad button 0 (A) jumps once");

// physical keys: the DOM code names the position, never the character, so the same code moves the same on any layout
const k1 = await moved(game, () => game.hold("KeyW"));
check(k1[1] < -0.5, "KeyW (the key at W's position, whatever it is labelled) moves forward");

// rebinding: conflicts, then a taken key, then the profile in storage
let r = game.rebind("jump key:KeyW");
check(r.ok === false && r.conflicts.join() === "move.up", `jump to W is refused, W is move.up: ${JSON.stringify(r)}`);
r = game.rebind("jump key:KeyJ");
check(r.ok === true, "jump to J is applied");
await tick();
check(storage.files.has("profile/actions.txt"), "the profile is in storage after a rebind");
check(new TextDecoder().decode(storage.files.get("profile/actions.txt")) === "ludens-profile 1\nset jump.main key:KeyJ pad:b0 vpad:b0\n", `profile text: ${JSON.stringify(new TextDecoder().decode(storage.files.get("profile/actions.txt") ?? new Uint8Array()))}`);
r = game.rebind("move.up key:KeyI");
check(r.ok === true, "move.up to I is applied");
check(game.prompt("jump", "keyboard") === "J" && game.prompt("move.up", "keyboard") === "I", "the prompts follow the rebinding: J and I");
game.configure(0, "bare");
await run(game, 60);
const jb = game.state().jumps;
game.press("Space"); await run(game, 3);
check(game.state().jumps === jb, "Space no longer jumps");
game.press("KeyJ"); await run(game, 3);
check(game.state().jumps === jb + 1, "J jumps");
const ki = await moved(game, () => game.hold("KeyI"));
const kw = await moved(game, () => game.hold("KeyW"));
check(ki[1] < -0.5 && Math.hypot(...kw) < 1e-6, "I moves forward and W no longer does");

// restart: a new module instance over the same storage restores the bindings, with no rebind call
game = await boot();
await run(game, 5);
check(game.prompt("jump", "keyboard") === "J" && game.prompt("move.up", "keyboard") === "I", "after a restart the prompts are J and I (restored from storage)");
const ki2 = await moved(game, () => game.hold("KeyI"));
const kw2 = await moved(game, () => game.hold("KeyW"));
check(ki2[1] < -0.5 && Math.hypot(...kw2) < 1e-6, "after a restart I moves forward and W does not");
game.configure(0, "bare");
await run(game, 60);
const jr = game.state().jumps;
game.press("KeyJ"); await run(game, 3);
check(game.state().jumps === jr + 1, "after a restart J jumps");

// a profile row that is wrong does not stop the others from loading
const enc = new TextEncoder();
await storage.write("profile/actions.txt", enc.encode("ludens-profile 1\nset jump.main key:KeyQ\nset nothing.main key:KeyX\nset move.up key:Nope\n"));
game = await boot();
await run(game, 5);
check(game.prompt("jump", "keyboard") === "Q" && game.prompt("move.up", "keyboard") === "W", "a hand-edited profile: the good row applies, the unknown action and key are skipped");

game.resetBindings();
await tick();
check(new TextDecoder().decode(storage.files.get("profile/actions.txt")) === "ludens-profile 1\n" && game.prompt("jump", "keyboard") === "Space", "resetBindings puts the defaults back and rewrites the profile");

console.log(`test_input: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
