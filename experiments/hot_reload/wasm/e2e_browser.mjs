// ===========================================================================
// End-to-end check of the browser hot-reload loop (driven by e2e.py).
//
// Opens the dev-server page in headless Chromium, then edits the watched
// source file three times and checks what the running page did:
//   edit 1  code-only (SPEED, COLOR)     -> swapped via memcopy-rw, state kept
//   edit 2  syntax error                  -> build error reported, old module keeps running
//   edit 3  fix + struct layout change    -> swapped via snapshot, state kept
//
//   node experiments/hot_reload/wasm/e2e_browser.mjs <pageUrl> <watchedSource> <outDir>
// ===========================================================================
import { execSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join } from "node:path";

const [url, source, outDir] = process.argv.slice(2);

function loadPlaywright() {
  try {
    return createRequire(import.meta.url)("playwright");
  } catch {
    const globalRoot = execSync("npm root -g").toString().trim();
    return createRequire(join(globalRoot, "noop.js"))("playwright");
  }
}
const { chromium } = loadPlaywright();

const RED = 0xff0000ff, GREEN = 0x00ff00ff;
const results = [];
let ok = true;
const check = (name, cond, detail) => {
  ok &&= !!cond;
  results.push({ name, pass: !!cond, detail });
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${detail === undefined ? "" : "  " + JSON.stringify(detail)}`);
};

const browser = await chromium.launch(
  process.env.PLAYWRIGHT_BROWSERS_PATH ? {} : { executablePath: "/opt/pw-browsers/chromium" });
const page = await browser.newPage();
const pageErrors = [];
page.on("pageerror", (e) => pageErrors.push(String(e)));

const hot = () => page.evaluate(() => structuredClone(window.__hot));
const waitFor = (fn, arg, timeout = 20000) => page.waitForFunction(fn, arg, { timeout, polling: 50 });

const original = await readFile(source, "utf8");
try {
  await page.goto(url);
  await waitFor(() => window.__hot && window.__hot.frame > 30);
  let s = await hot();
  check("boot: 10 entities (12 minus 2 despawned), red", s.count === 10 && s.color === RED, { count: s.count, color: s.color });

  // edit 1: code-only
  await writeFile(source, "#define SPEED 120.0f\n#define COLOR 0x00ff00ffu\n" + original);
  await waitFor(() => window.__hot.reloads.length === 1);
  await waitFor(() => window.__hot.color === 0x00ff00ff);
  s = await hot();
  let r = s.reloads[0];
  check("edit 1 swapped via memcopy-rw", r.strategy === "memcopy-rw", r);
  check("edit 1 frame counter continued across swap", r.frameAfter === r.frameBefore && r.frameBefore > 30, r);
  check("edit 1 entity set kept (10) and new color live", s.count === 10 && s.color === GREEN, { count: s.count, color: s.color });

  // edit 2: broken source
  const frameAtBreak = s.frame;
  await writeFile(source, "#define SPEED 120.0f\n#define COLOR 0x00ff00ffu\n" + original + "\nthis is not C;\n");
  await waitFor(() => window.__hot.errors.length === 1);
  await waitFor((f) => window.__hot.frame > f + 10, frameAtBreak);
  s = await hot();
  check("edit 2 build error reported, old module still running", s.reloads.length === 1 && s.version === 2 && s.frame > frameAtBreak + 10,
        { errors: s.errors, version: s.version, frame: s.frame });

  // edit 3: fix + layout change
  await writeFile(source, "#define SPEED 120.0f\n#define COLOR 0x00ff00ffu\n#define LAYOUT_V2\n" + original);
  await waitFor(() => window.__hot.reloads.length === 2);
  await page.waitForTimeout(200);
  s = await hot();
  r = s.reloads[1];
  check("edit 3 swapped via snapshot (layout changed)", r.strategy === "snapshot", r);
  check("edit 3 frame counter continued across swap", r.frameAfter === r.frameBefore, r);
  check("edit 3 entity set kept (10), still green", s.count === 10 && s.color === GREEN, { count: s.count, color: s.color });

  check("no uncaught page errors", pageErrors.length === 0, pageErrors);
  await page.screenshot({ path: join(outDir, "screenshot.png") });
  await writeFile(join(outDir, "e2e.json"), JSON.stringify({ results, reloads: s.reloads, errors: s.errors }, null, 2));
} catch (err) {
  check("e2e ran to completion", false, String(err));
} finally {
  await writeFile(source, original);
  await browser.close();
}
if (!ok) process.exit(1);
console.log("PASS  browser hot reload: edit -> rebuild -> swap, state kept");
