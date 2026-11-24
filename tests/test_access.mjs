// The accessibility settings end to end through the wasm64 app under node (ludens-engine #118), no WebGPU: the settings and their ranges,
// the one profile file shared with the input bindings and restored by a second module instance, captions raised by the mixer's
// events and by dialogue, camera shake scaled by the player, and the player's volumes and mono output in the mixed audio.
// usage: node --experimental-strip-types tests/test_access.mjs build/app.wasm <ludens-wasm-rt host.mjs> <wgpu-mojo dir> <miniaudio-mojo dir> <audio dir>

const [wasm, hostMjs, wgpuDir, maDir, audioDir] = process.argv.slice(2);
const { bootApp } = await import(new URL("../scripts/node_app.mjs", import.meta.url));
const { memoryStorage } = await import(new URL("../shell/web/os_host.mjs", import.meta.url));
const { createGameHook } = await import(new URL("../shell/web/game_hook.mjs", import.meta.url));
const { keyCode } = await import(new URL("../shell/web/keys.ts", import.meta.url));
let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const tick = () => new Promise((r) => setTimeout(r, 0));
const storage = memoryStorage();
const dec = (name) => new TextDecoder().decode(storage.files.get(name) ?? new Uint8Array());

async function boot() {
  const { rt } = await bootApp({ wasm, hostMjs, wgpuDir, maDir, storage });
  const [ptr, len] = rt.str_in("#canvas");
  const app = rt.call("app_init", ptr, len, 640, 480);
  if (rt.call("app_set_mode", app, 1) !== 0) throw new Error("app_set_mode failed");
  const game = createGameHook({ rt, app, keyCode });
  game.configure(0, "bare");
  game.rt = rt;
  game.app = app;
  const buf = rt.alloc(4800 * 2 * 4);
  /** `frames` stereo frames from the mixer, as one Float32Array of interleaved samples. */
  game.audio = (frames) => {
    const out = new Float32Array(frames * 2);
    for (let done = 0; done < frames; done += 4800) {
      const n = Math.min(4800, frames - done);
      if (rt.call("app_audio_render", app, buf, n) !== 0) throw new Error("app_audio_render failed");
      out.set(rt.f32(buf, n * 2), done * 2);
    }
    return out;
  };
  return game;
}
const run = async (game, n) => { for (let i = 0; i < n; i++) { game.step(1, false); await tick(); } };
const throws = (fn) => { try { fn(); return false; } catch { return true; } };
const rms = (a) => Math.sqrt(a.reduce((s, v) => s + v * v, 0) / a.length);

// ---- settings, ranges, the profile file
let game = await boot();
await run(game, 3);
check(game.accessText() === "", "all defaults: no access rows");
game.access("text_scale 150");
game.access("volume.music 40");
game.access("colorblind deuteranopia");
game.access("mono on");
check(game.accessText() === "access text_scale 150\naccess colorblind deuteranopia\naccess volume.music 40\naccess mono on\n", `rows: ${JSON.stringify(game.accessText())}`);
check(throws(() => game.access("text_scale 250")) && throws(() => game.access("text_scale 99")), "text scale outside 100 .. 200 is refused");
check(throws(() => game.access("shake 101")) && throws(() => game.access("volume.sfx -1")) && throws(() => game.access("colorblind green")) && throws(() => game.access("nothing 1")), "other bad values are refused");
check(game.accessText().includes("text_scale 150"), "a refused value leaves the setting as it was");
await tick();
check(dec("profile/actions.txt") === game.accessText().replace(/^/, "ludens-profile 1\n"), `the settings are in the profile file: ${JSON.stringify(dec("profile/actions.txt"))}`);

// a rebind afterwards keeps the access rows; both live in the one file
check(game.rebind("jump key:KeyJ").ok === true, "jump rebound to J");
await tick();
const file = dec("profile/actions.txt");
check(file === "ludens-profile 1\nset jump.main key:KeyJ pad:b0 vpad:b0\n" + game.accessText(), `one file holds the binding and the settings: ${JSON.stringify(file)}`);

// restart on the same storage: both come back
game = await boot();
await run(game, 5);
check(game.accessText() === "access text_scale 150\naccess colorblind deuteranopia\naccess volume.music 40\naccess mono on\n", "after a restart the settings are restored from the profile file");
check(game.prompt("jump", "keyboard") === "J", "after a restart the binding is restored too");

// a hand-edited profile: the bad access rows are skipped, the good ones and the bindings still apply
await storage.write("profile/actions.txt", new TextEncoder().encode("ludens-profile 1\nset jump.main key:KeyQ\naccess text_scale 20\naccess shake 30\naccess volume.drums 5\naccess captions on\n"));
game = await boot();
await run(game, 5);
check(game.accessText() === "access shake 30\naccess captions on\n" && game.prompt("jump", "keyboard") === "Q", `bad rows skipped, good rows applied: ${JSON.stringify(game.accessText())}`);
game.resetAccess();
await tick();
check(game.accessText() === "" && dec("profile/actions.txt") === "ludens-profile 1\nset jump.main key:KeyQ\n", "resetAccess puts the defaults back and the profile loses the access rows but keeps the binding");

game.resetBindings();
await tick();
check(dec("profile/actions.txt") === "ludens-profile 1\n", "resetBindings: the profile is back to its header");

// ---- captions: an audio event raises its caption, dialogue is a caption, both expire
const TRACK = "ludens-captions 1\ncaption cue1 duration=500 speaker=who text=jump\ntext en who Ball\ntext en jump jumps\n";
game = await boot();
game.captionsLoad(TRACK);
check(throws(() => game.captionsLoad("caption x\n")), "a track without its header is refused");
await run(game, 60);
check(game.captions().length === 0, "no caption before the jump");
game.press("Space");
await run(game, 3);
check(JSON.stringify(game.captions()) === '["Ball: jumps"]', `the jump's sound event raises its caption: ${JSON.stringify(game.captions())}`);
await run(game, 20);
check(game.captions().length === 1, "still up 23 frames (380 ms) after the jump (500 ms row)");
await run(game, 15);
check(game.captions().length === 0, "gone after 38 frames (630 ms)");
game.say("Mara", "Over here!", 300);
check(JSON.stringify(game.captions()) === '["Mara: Over here!"]', "dialogue: speaker and line");
game.access("caption_speaker off");
check(JSON.stringify(game.captions()) === '["Over here!"]', "speaker names off");
await run(game, 20);
check(game.captions().length === 0, "dialogue expires after its 300 ms");

// ---- camera shake
game = await boot();
await run(game, 3);
game.shake(1);
const full = game.shakeOffset();
check(Math.hypot(...full) > 0.01 && Math.hypot(...full) <= 0.3 * Math.SQRT2 + 1e-9, `shake at 100 %: moves ${Math.hypot(...full).toFixed(4)} m`);
game.access("shake 50");
const half = game.shakeOffset();
check(Math.abs(half[0] - full[0] / 2) < 1e-9 && Math.abs(half[1] - full[1] / 2) < 1e-9, "shake 50 %: half the offset on both axes");
game.access("shake 0");
check(game.shakeOffset().every((v) => v === 0), "shake 0: no offset");
game.access("shake 100");
game.access("reduce_motion on");
check(game.shakeOffset().every((v) => v === 0), "reduce motion: no offset with the slider at 100 %");
game.access("reduce_motion off");
check(Math.hypot(...game.shakeOffset()) > 0.01, "reduce motion off: the shake is back");

// ---- audio: the player's volume per bus and mono reach the mixed output
async function jumpAudio(settings) {
  const g = await boot();
  for (const s of settings) g.access(s);
  await run(g, 60);
  g.audio(4800);
  g.press("Space");
  await run(g, 2);
  return g.audio(14400);
}
const base = await jumpAudio([]);
const master50 = await jumpAudio(["volume.master 50"]);
const sfx0 = await jumpAudio(["volume.sfx 0"]);
const music0 = await jumpAudio(["volume.music 0"]);
const mono = await jumpAudio(["mono on"]);
check(rms(base) > 1e-4, `the jump is audible: rms ${rms(base).toExponential(3)}`);
check(Math.abs(rms(master50) / rms(base) - 0.5) < 0.005, `volume.master 50: rms ratio ${(rms(master50) / rms(base)).toFixed(4)} (0.5 expected)`);
check(rms(sfx0) === 0, "volume.sfx 0: the jump (an sfx event) is silent");
check(rms(music0) === rms(base), "volume.music 0 does not change the jump");
// the shipped stereo music: left and right differ there, so mono has something to fold
const { readFileSync } = await import("node:fs");
async function musicAudio(settings) {
  const g = await boot();
  const put = (bytes) => { const p = g.rt.alloc(Math.max(1, bytes.length)); g.rt.put(p, bytes); return p; };
  for (const name of readFileSync(`${audioDir}/index.txt`, "utf8").split("\n").filter(Boolean)) {
    const n = new TextEncoder().encode(name), b = readFileSync(`${audioDir}/${name}`);
    if (g.rt.call("app_load_audio", g.app, put(n), BigInt(n.length), put(b), BigInt(b.length)) !== 0) throw new Error(`load ${name}`);
  }
  const t = new TextEncoder().encode("calm");
  if (g.rt.call("app_music", g.app, put(t), BigInt(t.length)) !== 0) throw new Error("app_music");
  for (const s of settings) g.access(s);
  await run(g, 10);
  g.audio(48000); // let the music start on the bar line
  return g.audio(24000);
}
const musicBase = await musicAudio([]);
const musicMono = await musicAudio(["mono on"]);
const musicQuiet = await musicAudio(["volume.music 50"]);
const lr = (a) => { let m = 0; for (let i = 0; i < a.length; i += 2) m = Math.max(m, Math.abs(a[i] - a[i + 1])); return m; };
check(lr(mono) === 0, "mono on: the jump has left equal to right in every frame");
// The jump and the shipped music are both centred (L == R before mono), so these two checks cannot show the fold itself; that is
// tests/audio_mixer.mojo (a clip of 0.8 left and 0.2 right becomes 0.5 and 0.5). Here: the setting reaches the mixer without a crash.
check(rms(musicBase) > 1e-4, `the music plays: rms ${rms(musicBase).toExponential(3)}`);
check(lr(musicMono) === 0, "mono on: the music has left equal to right in every frame");
check(rms(musicMono) > 0.3 * rms(musicBase), `mono on: the music is still there (rms ${rms(musicMono).toExponential(3)} against ${rms(musicBase).toExponential(3)})`);
check(Math.abs(rms(musicQuiet) / rms(musicBase) - 0.5) < 0.01, `volume.music 50: the music's rms ratio ${(rms(musicQuiet) / rms(musicBase)).toFixed(4)} (0.5 expected)`);

console.log(`test_access: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
