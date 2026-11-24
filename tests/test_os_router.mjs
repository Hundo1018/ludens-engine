// The shared os_poll reader (app/os_router.mojo, ludens-engine #117): the input profile, the save seam and the clipboard each have a
// request in flight at once, and each gets exactly its own result, whichever of them polls first.
// usage: node tests/test_os_router.mjs build/os_router_probe.wasm <ludens-wasm-rt host.mjs>
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { createOsImports, memoryStorage } from "../shell/web/os_host.mjs";

const [wasm, hostMjs] = process.argv.slice(2);
const { instantiate } = await import(pathToFileURL(hostMjs));
let passed = 0, failed = 0;
const check = (cond, label) => { cond ? passed++ : failed++; console.log(`  [${cond ? "PASS" : "FAIL"}] ${label}`); };
const tick = () => new Promise((r) => setTimeout(r, 0));
const enc = new TextEncoder();

async function scenario(order) {
  const storage = memoryStorage();
  await storage.write("profile/actions.txt", enc.encode("ludens-profile 1\nset jump.main key:KeyJ pad:b0 vpad:b0\n"));
  const save = Uint8Array.from({ length: 200 }, (_, i) => (i * 7 + 2) & 255);
  await storage.write("saves/run/a.0", save);
  const clipboard = { writeText: async () => {}, readText: async () => "clip text" };
  const rt = await instantiate(readFileSync(wasm), { libs: [(r) => createOsImports(r, { clipboard, storage })] });
  const h = rt.call("p_new");
  const [sp, sl] = rt.str_in("run/a.0");
  // all three requests in flight before anything is polled
  const rc = [rt.call("p_request_profile", h), rt.call("p_request_save", h, 41, sp, sl), rt.call("p_request_clipboard")];
  check(rc.every((v) => v === 0), `[${order}] the profile read, the save read and the clipboard read are all queued`);
  await tick(); await tick();
  const buf = rt.alloc(4096);
  const got = { profile: false, save: null, clip: null };
  const pollers = {
    save: () => { const n = rt.call("p_poll_save", h, buf, 4096); if (n > 0) got.save = rt.bytes(buf, n).slice(); },
    profile: () => { got.profile = rt.call("p_poll_profile", h) === 1; },
    clip: () => { const n = rt.call("p_poll_clipboard", h, buf, 4096); if (n > 0) got.clip = rt.bytes(buf, n).slice(); },
  };
  for (const who of order.split(",")) for (let i = 0; i < 3; i++) pollers[who]();
  check(got.profile && rt.call("p_jump_key_is_j", h) === 1, `[${order}] the profile was applied: jump is on J`);
  const b = got.save;
  check(b && b[0] === 20 && new DataView(b.buffer).getUint32(1, true) === 41 && b[5] === 0 && b.length === 206 && b.slice(6).every((v, i) => v === save[i]),
        `[${order}] the save read arrived as KIND_SAVE_READ with id 41 and its 200 bytes`);
  const c = got.clip;
  check(c && c[0] === 1 && new TextDecoder().decode(c.slice(6)) === "clip text", `[${order}] the clipboard text arrived`);
  check(rt.call("p_foreign", h) === 0, `[${order}] nothing was dropped as foreign`);
}

// every order of the three consumers: the one that polls first used to take, and drop, the others' packets
for (const order of ["save,profile,clip", "profile,save,clip", "clip,save,profile", "save,clip,profile"]) await scenario(order);

console.log(`os_router: ${passed} / ${passed + failed} checks`);
process.exit(failed ? 1 : 0);
