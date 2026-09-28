"""Golden-output tool: the identity gate for behaviour-preserving changes.

A refactor that claims "behaviour unchanged" is checked by comparing the test
suite's printed output with a recorded golden copy, file section by file
section. Timing lines differ run to run and must be dropped first; everything
else must match exactly.

The normalizer is part of the gate, so it is tested (`selftest`): its first
shell version matched `ns\\b` / `ms\\b` anywhere and silently dropped every line
containing "relations", "items" or "systems" from BOTH sides of the diff,
weakening the gate without failing it. Units are therefore only recognised
right after a digit, and the selftest pins lines that must survive as well as
lines that must go.

Usage (`pixi run golden -- <cmd>`):
  normalize LOG            print LOG's lines that the gate compares
  compare GOLDEN LOG       per-file sections: missing / changed -> exit 1;
                           new sections are listed but allowed
  summary LOG              files / passed / failed / warnings / arch / tiers;
                           exit 1 unless the run is complete and clean
  selftest                 fixture checks of normalize, compare and summary
"""

from std.sys import argv, exit


# ---------------------------------------------------------------- normalize


@always_inline
def _is_digit(b: UInt8) -> Bool:
    return b >= 48 and b <= 57


@always_inline
def _is_letter(b: UInt8) -> Bool:
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b >= 128


def _unit_after_digit(line: String, unit: String) -> Bool:
    """True if `unit` appears right after a digit (one optional space between)
    and is not followed by a letter: `3.2 ms`, `12ns/op`, but not `items`."""
    var bytes = line.as_bytes()
    var ub = unit.as_bytes()
    var n = len(bytes)
    var m = len(ub)
    for i in range(n - m + 1):
        var hit = True
        for k in range(m):
            if bytes[i + k] != ub[k]:
                hit = False
                break
        if not hit:
            continue
        var j = i - 1
        if j >= 0 and bytes[j] == 32:
            j -= 1
        if j < 0 or not _is_digit(bytes[j]):
            continue
        var after = i + m
        if after < n and _is_letter(bytes[after]):
            continue
        return True
    return False


def _ratio_after_digit(line: String) -> Bool:
    """`1.5x` / `12x ` style ratios (a digit, then `x`, then no letter)."""
    var bytes = line.as_bytes()
    var n = len(bytes)
    for i in range(1, n):
        if bytes[i] == 120 and _is_digit(bytes[i - 1]):
            if i + 1 >= n or not _is_letter(bytes[i + 1]):
                return True
    return False


def keep(line: String) -> Bool:
    """Whether the identity gate compares this line."""
    var s = String(line.strip())
    if s.byte_length() == 0:
        return False
    var prefixes: List[String] = [
        "real\t", "user\t", "sys\t", "✨ Pixi task", "arch check:", "tiers:",
        "exit=", "EXIT:",
    ]
    for i in range(len(prefixes)):
        if line.startswith(prefixes[i]):
            return False
    if " declared=" in line or "Mops" in line or "speedup" in line:
        return False
    var units: List[String] = ["ms", "ns", "us", "µs", "sec", "seconds"]
    for i in range(len(units)):
        if _unit_after_digit(line, units[i]):
            return False
    if _ratio_after_digit(line):
        return False
    var low = line.lower()
    var words: List[String] = ["elapsed", "took ", "per sec", "wall time", "time:", "ms/"]
    for i in range(len(words)):
        if words[i] in low:
            return False
    return True


def normalize(lines: List[String]) -> List[String]:
    var out = List[String]()
    for l in lines:
        if keep(l):
            out.append(l)
    return out^


# ---------------------------------------------------------------- sections


@fieldwise_init
struct Section(Copyable, Movable):
    var name: String
    var lines: List[String]


def sections(lines: List[String]) -> List[Section]:
    """Split on runner headers `--- tests/<file> ---`; lines before the first
    header form a section named `(preamble)`."""
    var out = List[Section]()
    out.append(Section("(preamble)", List[String]()))
    for l in lines:
        if l.startswith("--- tests/") and l.endswith(" ---"):
            out.append(Section(l, List[String]()))
        else:
            out[len(out) - 1].lines.append(l)
    return out^


def _find(secs: List[Section], name: String) -> Int:
    for i in range(len(secs)):
        if secs[i].name == name:
            return i
    return -1


@fieldwise_init
struct Verdict(Copyable, Movable):
    var missing: List[String]
    var changed: List[String]
    var added: List[String]

    def ok(self) -> Bool:
        return len(self.missing) == 0 and len(self.changed) == 0


def compare(golden: List[String], log: List[String]) -> Verdict:
    """Section-wise: order of files may change (tiers reorder the runner),
    content inside a file section may not. `(preamble)` is not compared."""
    var g = sections(normalize(golden))
    var o = sections(normalize(log))
    var v = Verdict(List[String](), List[String](), List[String]())
    for i in range(1, len(g)):
        var j = _find(o, g[i].name)
        if j < 0:
            v.missing.append(g[i].name)
            continue
        var same = len(g[i].lines) == len(o[j].lines)
        if same:
            for k in range(len(g[i].lines)):
                if g[i].lines[k] != o[j].lines[k]:
                    same = False
                    break
        if not same:
            v.changed.append(g[i].name)
    for j in range(1, len(o)):
        if _find(g, o[j].name) < 0:
            v.added.append(o[j].name)
    return v^


def _show_change(golden: List[String], log: List[String], name: String):
    var g = sections(normalize(golden))
    var o = sections(normalize(log))
    var a = g[_find(g, name)].lines.copy()
    var b = o[_find(o, name)].lines.copy()
    var n = max(len(a), len(b))
    var shown = 0
    for k in range(n):
        var x = a[k] if k < len(a) else String("(none)")
        var y = b[k] if k < len(b) else String("(none)")
        if x != y and shown < 4:
            print("    golden:", x)
            print("    now:   ", y)
            shown += 1


# ---------------------------------------------------------------- summary


@fieldwise_init
struct Summary(Copyable, Movable):
    var files: Int
    var passed: Int
    var failed: Int
    var warnings: Int
    var errors: Int
    var all_passed: Bool
    var arch: String
    var tiers: String

    def ok(self) -> Bool:
        return (
            self.all_passed
            and self.failed == 0
            and self.warnings == 0
            and self.errors == 0
            and self.files == self.passed
        )


def summarize(lines: List[String]) -> Summary:
    """What an agent reports after a suite run, computed the same way every
    time instead of each agent assembling its own grep."""
    var s = Summary(0, 0, 0, 0, 0, False, String("(none)"), String("(none)"))
    for l in lines:
        if l.startswith("--- tests/") and l.endswith(" ---"):
            s.files += 1
        elif l.startswith("[PASS] "):
            s.passed += 1
        elif "[FAIL]" in l:
            s.failed += 1
        elif l.startswith("all tests passed"):
            s.all_passed = True
        elif l.startswith("arch check:"):
            s.arch = String(l.strip())
        elif l.startswith("tiers:"):
            s.tiers = String(l.strip())
        # Compiler diagnostics are `path:line:col: warning:` / `mojo: error:`;
        # a bare "error:" also appears in physics output ("worst inversion
        # error: 4.6e-06"), which the first version of this counted.
        if ": warning:" in l:
            s.warnings += 1
        if ": error:" in l:
            s.errors += 1
    return s^


def print_summary(s: Summary):
    print("SUITE  files", s.files, " passed", s.passed, " failed", s.failed,
          " warnings", s.warnings, " errors", s.errors)
    print("ARCH  ", s.arch)
    print("TIERS ", s.tiers)
    print("RESULT", "PASS" if s.ok() else "FAIL")


# ---------------------------------------------------------------- selftest


def _lines(text: String) -> List[String]:
    var out = List[String]()
    for l in text.splitlines():
        out.append(String(l))
    return out^


def selftest() -> Bool:
    var passed = 0
    var failed = 0

    # Lines the gate must KEEP (the first normalizer dropped the first four).
    var kept: List[String] = [
        "--- tests/test_relations.mojo ---",
        "[PASS] relations - 19 / 19 checks",
        "  items 5  systems 3  tokens 2",
        "  mean 0.25 over 12 bins",
        "  max force at rest: 1.21327375e-05",
        "  rest height: 0.2497",
        "  2 sensors, 3 steps, 4 axes",
    ]
    for i in range(len(kept)):
        if keep(kept[i]):
            passed += 1
        else:
            failed += 1
            print("  [FAIL] dropped a line it must keep:", kept[i])

    # Lines the gate must DROP (timing and runner chrome).
    var dropped: List[String] = [
        "real\t4m37.928s",
        "  step 3.2 ms",
        "  12ns/op",
        "  build 250 µs",
        "  2.5 seconds total",
        "  wheel 1.5x faster",
        "  1.2 Mops/s",
        "✨ Pixi task (arch): bash scripts/arch.sh check",
        "arch check: OK (146 modules, 687 edges)",
        "tiers: 138/138 have a valid header",
        "test_aabb.mojo  declared=unit  span=[geometry]  suggested=unit  OK",
        "exit=0",
        "   ",
        "  Elapsed: 3",
    ]
    for i in range(len(dropped)):
        if not keep(dropped[i]):
            passed += 1
        else:
            failed += 1
            print("  [FAIL] kept a line it must drop:", dropped[i])

    var golden = _lines(
        "all tests\n--- tests/test_a.mojo ---\n  v 1.5\n[PASS] a - 2 / 2"
        " checks\n--- tests/test_b.mojo ---\n[PASS] b - 1 / 1 checks"
    )
    # Same content, files reordered, timing lines added: must pass.
    var reordered = _lines(
        "--- tests/test_b.mojo ---\n  took 3 ms\n[PASS] b - 1 / 1 checks\n---"
        " tests/test_a.mojo ---\n  v 1.5\n  8.1 ms\n[PASS] a - 2 / 2 checks"
    )
    var v1 = compare(golden, reordered)
    if v1.ok() and len(v1.added) == 0:
        passed += 1
    else:
        failed += 1
        print("  [FAIL] reordered + timing-only log should compare equal")

    # A changed value must fail, a missing file must fail, a new file is allowed.
    var changed = _lines(
        "--- tests/test_a.mojo ---\n  v 1.6\n[PASS] a - 2 / 2 checks\n---"
        " tests/test_c.mojo ---\n[PASS] c - 1 / 1 checks"
    )
    var v2 = compare(golden, changed)
    if (
        len(v2.changed) == 1
        and len(v2.missing) == 1
        and len(v2.added) == 1
        and not v2.ok()
    ):
        passed += 1
    else:
        failed += 1
        print("  [FAIL] changed value / missing file / new file not classified")

    # Negative control: a gate that cannot fail is not a gate.
    var v3 = compare(golden, _lines("--- tests/test_a.mojo ---\n[PASS] a - 1 / 2 checks"))
    if not v3.ok():
        passed += 1
    else:
        failed += 1
        print("  [FAIL] negative control passed")

    # Summary: a clean run, a failing file, a warning, a truncated run.
    var clean = summarize(_lines(
        "arch check: OK (1 modules, 0 edges)\ntiers: 2/2 have a valid"
        " header\n--- tests/test_a.mojo ---\n  worst inversion error:"
        " 4.6e-06\n  relative error: 0.01\n[PASS] a - 1 / 1 checks\n---"
        " tests/test_b.mojo ---\n[PASS] b - 2 / 2 checks\nall tests passed"
    ))
    var failing = summarize(_lines(
        "--- tests/test_a.mojo ---\n  [FAIL] a - x\n[PASS] a - 1 / 2 checks"
    ))
    var warned = summarize(_lines(
        "t.mojo:3:1: warning: unused\n--- tests/test_a.mojo ---\n[PASS] a -"
        " 1 / 1 checks\nall tests passed"
    ))
    var broken = summarize(_lines(
        "t.mojo:9:5: error: use of unknown declaration\nmojo: error: failed"
    ))
    var truncated = summarize(_lines(
        "--- tests/test_a.mojo ---\n[PASS] a - 1 / 1 checks\n---"
        " tests/test_b.mojo ---"
    ))
    if (
        clean.ok() and clean.files == 2 and clean.arch.startswith("arch check")
        and not failing.ok() and failing.failed == 1
        and not warned.ok() and warned.warnings == 1
        and not truncated.ok()
        and broken.errors == 2 and not broken.ok()
    ):
        passed += 1
    else:
        failed += 1
        print("  [FAIL] summary misclassified a fixture run")

    print("golden selftest:", String(passed) + "/" + String(passed + failed))
    return failed == 0


# ---------------------------------------------------------------- main


def _read(path: String) raises -> List[String]:
    var f = open(path, "r")
    var text = f.read()
    f.close()
    return _lines(text)


def main() raises:
    var args = argv()
    if len(args) < 2:
        print("usage: golden normalize LOG | compare GOLDEN LOG | summary LOG | selftest")
        exit(2)
    var cmd = String(args[1])
    if cmd == "selftest":
        if not selftest():
            exit(1)
        return
    if cmd == "summary" and len(args) == 3:
        var sm = summarize(_read(String(args[2])))
        print_summary(sm)
        if not sm.ok():
            exit(1)
        return
    if cmd == "normalize" and len(args) == 3:
        for l in normalize(_read(String(args[2]))):
            print(l)
        return
    if cmd == "compare" and len(args) == 4:
        var golden = _read(String(args[2]))
        var log = _read(String(args[3]))
        var v = compare(golden, log)
        for name in v.missing:
            print("  MISSING", name)
        for name in v.changed:
            print("  CHANGED", name)
            _show_change(golden, log, name)
        for name in v.added:
            print("  NEW    ", name)
        if v.ok():
            print("golden: OK (" + String(len(v.added)) + " new file sections)")
            return
        print(
            "golden: FAIL (" + String(len(v.missing)) + " missing, "
            + String(len(v.changed)) + " changed)"
        )
        exit(1)
    print("usage: golden normalize LOG | compare GOLDEN LOG | summary LOG | selftest")
    exit(2)
