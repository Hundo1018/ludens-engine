// Reference counts for TextureView handles on the web (#139).
//
// The renderer's stages share views: a target is the output of one stage and the input of the next, so each holder takes
// `TextureView.clone()`, which calls `wgpuTextureViewAddRef`. The browser host in wgpu-mojo (web/webgpu_host.mjs) traps
// on that call ("unimplemented on web"), and its `wgpuTextureViewRelease` deletes the handle at the first release, so
// the stage pipelines (app/post.mojo, app/post_fx.mojo) could not run in a browser. This wraps the two imports: an
// AddRef counts an extra holder, a Release removes one, and the handle is deleted when the last holder releases.
// A handle that never had an AddRef behaves as before.
export function withViewRefs(env) {
  const extra = new Map();
  const release = env.wgpuTextureViewRelease;
  env.wgpuTextureViewAddRef = (h) => {
    const k = BigInt(h);
    extra.set(k, (extra.get(k) ?? 0) + 1);
  };
  env.wgpuTextureViewRelease = (h) => {
    const k = BigInt(h);
    const n = extra.get(k) ?? 0;
    if (n > 1) extra.set(k, n - 1);
    else if (n === 1) extra.delete(k);
    else release(h);
  };
  return env;
}
