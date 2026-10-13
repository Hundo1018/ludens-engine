# tier: unit  (override: runs tests/probes/trace_on_probe.mojo as a subprocess; the probe steps a physics scene)
"""Trace switches that need `-D LUDENS_TRACE` (ROADMAP 17.80).

The test suite builds without tracing, where every span is compiled out, so
this test runs `tests/probes/trace_on_probe.mojo` with `-D LUDENS_TRACE` and
`-D ASSERT=all` in a subprocess and passes if the probe does. The probe
checks the run-time `enabled` switch on a real solver step, nesting across
a mid-span toggle, ring mode, counter (`C`) events in the Chrome export and
the `TRACE_DROPPED` counter.
"""

from std.python import Python
from harness.runner import Suite


def main() raises:
    var s = Suite("trace_runtime")
    var sp = Python.import_module("subprocess")
    var r = sp.run(
        Python.list("mojo", "run", "--target-cpu", "skylake", "-D", "LUDENS_TRACE", "-D", "ASSERT=all", "-I", "build", "tests/probes/trace_on_probe.mojo"),
        capture_output=True, text=True,
    )
    print(String(r.stdout).strip())
    if Int(py=r.returncode) != 0:
        print(String(r.stderr))
    s.check(Int(py=r.returncode) == 0, "the -D LUDENS_TRACE probe passes")
    s.finish()
