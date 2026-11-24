// shell/web/view_refs.mjs: TextureView.clone() on the web (#139). A handle with extra holders is deleted by the last
// release; one without is deleted by its first, as before.  node tests/test_view_refs.mjs
import { withViewRefs } from "../shell/web/view_refs.mjs";

let failed = 0;
function check(cond, label) {
  console.log(`${cond ? "[PASS]" : "[FAIL]"} view_refs - ${label}`);
  if (!cond) failed++;
}

function make() {
  const dropped = [];
  const env = { wgpuTextureViewRelease: (h) => dropped.push(BigInt(h)) };
  return { env: withViewRefs(env), dropped };
}

{
  const { env, dropped } = make();
  env.wgpuTextureViewRelease(7n);
  check(dropped.length === 1 && dropped[0] === 7n, "a handle that was never cloned is dropped by its first release");
}
{
  const { env, dropped } = make();
  env.wgpuTextureViewAddRef(7n);
  env.wgpuTextureViewAddRef(7n);
  env.wgpuTextureViewRelease(7n);
  env.wgpuTextureViewRelease(7n);
  check(dropped.length === 0, "two clones: two releases drop nothing");
  env.wgpuTextureViewRelease(7n);
  check(dropped.length === 1 && dropped[0] === 7n, "the third release drops the handle, once");
  env.wgpuTextureViewRelease(7n);
  check(dropped.length === 2, "a release after that reaches the host again (the handle's count is back to zero)");
}
{
  const { env, dropped } = make();
  env.wgpuTextureViewAddRef(1n);
  env.wgpuTextureViewRelease(2n);
  check(dropped.length === 1 && dropped[0] === 2n, "counts are per handle");
  env.wgpuTextureViewRelease(1n);
  check(dropped.length === 1, "and the clone of handle 1 is still held");
}
console.log(failed ? `[FAIL] view_refs - ${failed} checks failed` : "[PASS] view_refs - all checks");
process.exit(failed ? 1 : 0);
