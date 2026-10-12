# Security

Report a vulnerability privately through GitHub's
**Security → Report a vulnerability** form on this repository
(private vulnerability reporting), not in a public issue.

In scope: memory safety and input validation at the public boundaries — the
C ABI (`embed/capi.mojo`, `embed/ludens.h`), the Python package (`python/ludens`),
and snapshot / save loading (`physics/serialize.mojo`, `gameplay/save.mojo`),
which read untrusted bytes.

There is no release yet; fixes land on `main`.
