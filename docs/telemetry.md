# Telemetry and crash reports (issue #147)

The engine queues gameplay events and keeps what a crash report needs. Both go out only after the player opts in, and
both travel over the Transport seam (`platform/transport.mojo`). The collector server is not part of the engine. This
note gives the two wire formats in full, so a collector in any language can read them. `scripts/telemetry_read.py` is
the reference reader, and it is written from the tables below.

Code:

| file | what |
|---|---|
| `platform/telemetry.mojo` | `Telemetry`: consent, the bounded event queue, batches, the consent record (standard library only) |
| `platform/crash_report.mojo` | `CrashReporter` (log lines, black box, packed context), `encode_crash` / `decode_crash`, `CrashUpload` (next launch) |
| `app/telemetry_outbox.mojo` | `OutboxForward`: ludens-core `diag/outbox` records into the telemetry queue |
| `app/os_crash.mojo` | the `os_crash_arm(ptr, len)` import and `arm_web` |
| `shell/web/crash_host.mjs` | on the web: stack parsing, source map lookup, the report written from wasm memory |
| `scripts/wasm_sourcemap.py` | a source map from the module's DWARF line tables, and the module without debug sections |
| `scripts/telemetry_read.py` | the reference reader: one JSON object per file; `--map` maps crash frames afterwards |

Tests: `pixi run -e wasm test-telemetry` (CI: the `editor` workflow).

## Consent and identity

- **Not asked yet** (`CONSENT_UNSET`, the default) and **withdrawn** (`CONSENT_WITHDRAWN`): `record` returns
  `TEL_NO_CONSENT`, nothing is queued, `flush` sends nothing, and `CrashReporter` keeps no lines, black box or context.
- **Opt in:** `tel.grant(id)` with 16 random bytes. The caller supplies them: `crypto.getRandomValues` on the web,
  `/dev/urandom` natively. `install_id_from(a, b)` sets the version 4 and variant bits of RFC 9562, so the id prints as a
  UUID. Pass the same id to `CrashReporter.set_install_id`.
- **Withdraw:** `tel.withdraw()` empties the queue and zeroes the id. `CrashReporter.clear()` drops the lines, the black
  box and the context. On the web, call `arm_web` afterwards so the host is disarmed. If the player opts in again, the
  grant uses a new id.
- **Persisting the choice:** `encode_consent()` / `apply_consent(bytes)` hold the state and the id in 31 bytes. Write them
  to the CloudSave slot `CONSENT_SLOT` (`telemetry/consent`). `apply_consent` refuses a record with a bad magic, a bad
  checksum, a newer format or an unknown state, and leaves the state unchanged. The game then asks the player again.
- **No personal data:** an event holds numbers only (kind, tick, time, key, values) and has no string field. The batch
  header holds the install id, a session id that is random per launch, the build id (printable ASCII, at most 64 bytes)
  and numeric tags. A crash report carries the game's log lines, so a game must not log personal data into the reporter.

## Events and the queue

| kind | name | key | values |
|---:|---|---|---|
| 1 | `EV_LEVEL_START` | level | none |
| 2 | `EV_LEVEL_END` | level | outcome (game-defined), seconds in the level |
| 3 | `EV_DEATH` | level | cause, x, y, z (the game's fixed-point units) |
| 4 | `EV_PURCHASE` | item | price in the smallest currency unit, currency (ISO 4217 numeric) |
| 5 | `EV_SETTING_CHANGED` | setting | old, new |
| 6-255 | reserved | | |
| 256-65535 | the game's own | | up to 6 |

- The queue holds `capacity` events (default 1024). When it is full, the new event is dropped and counted (`TEL_DROPPED`,
  `dropped()`). The count since the previous batch goes into the next batch header.
- `flush(t)` encodes the oldest events that fit in one message: at most `min(MAX_BATCH_BYTES = 64 KiB, t.max_message())`.
  It removes them only when `send` returned `NET_OK`. On `NET_NO_PEER` or `NET_FULL` they stay queued for the next
  flush. After `max_batches` batches (default 8) with events still left, it returns `NET_FULL_LATER`.
- Measured in `tests/platform_telemetry.mojo`: 130 death events into a queue of 100 gives 100 queued and 30 dropped. With
  a 1000-byte `max_message`, one batch holds 16 death events (979 bytes). The 100 events go out as 7 batches, and the
  first header says 31 dropped.
- `OutboxForward.forward(outbox, tel, time_ms)` drains a ludens-core `Outbox`. A record (kind, tick, key, a, b) becomes the
  event (kind, tick, time_ms, key, [a, b]). Records the outbox dropped are counted in `outbox_dropped`, and kinds outside
  1..65535 in `skipped`. The outbox refuses a tick it has already delivered, so a rollback re-simulation does not send an
  event twice (`tests/outbox_forward.mojo`).
- **Tags** are up to 16 (key u32, value u32) pairs sent in every batch header. `set_tag(experiment, bucket)` records an
  A/B test bucket (#149).

## Batch format

All integers are little-endian. One batch is one Transport message.

| field | size | notes |
|---|---:|---|
| magic | 4 | `4C 54 45 4C` ("LTEL") |
| format | 2 | 1 |
| flags | 2 | 0 |
| install_id | 16 | |
| session_id | 8 | random per launch |
| seq | 4 | batches sent in this session, from 0 |
| dropped | 4 | events dropped since the previous batch |
| build_id_len, build_id | 1 + n | printable ASCII, n ≤ 64 |
| tag_count, tags | 1 + 8 × count | (key u32, value u32) |
| event_count | 4 | |
| events | | below |
| checksum | 8 | FNV-1a 64 over every byte before it |

An event is `kind u16 | value_count u8 | 0 u8 | tick i64 | time_ms u32 | key i64 | values i64 × value_count`, which is 24 + 8 ×
value_count bytes. `time_ms` counts from the start of the session.

## Crash reports

`CrashReporter` keeps the last `log_lines` lines (default 64, each cut to 512 bytes on a UTF-8 boundary). It also keeps the
latest black box, which is ludens-core `gameplay/blackbox` `pack` output or any bytes up to 4 MiB, plus the build id.
`arm(tick, session_ms)` packs these into the context block. Call it about once a second and after each `set_blackbox`.

- **Web.** A wasm trap ends the call into the module, so code in the module cannot write the report. `arm_web` packs the
  context and passes its address to the host (`os_crash_arm`). When a call into the module throws, the page calls
  `crash.capture(error)`. In `shell/web/app.ts` that is the frame loop's `catch`. `capture` copies the context out of
  linear memory without calling into the module, then parses the wasm frames of `error.stack` (V8 and Firefox forms).
  If a source map was given (the `sourceMap` option of `createOsImports`), it maps the frames to source lines. It writes
  the report to `saves/crash/pending`, which is the CloudSave slot `crash/pending` of `OsCloudSave`. If nothing is armed,
  nothing is written.
- **Native.** The code that calls a frame catches the raised error, builds the report with
  `encode_crash(reporter.context(), reason, frames)` and writes it with `save_crash(save, id, report)`. No native stack is
  collected (frames empty). A signal handler for faults is not built.
- **Next launch.** `CrashUpload.start(save, id)` reads the slot, and `step(save, t, granted)` is called each frame. A valid
  report is sent as one Transport message if the player has opted in, and then the slot is cleared by writing an empty
  file. Results:
  - `UP_SENT`: sent, then the slot cleared.
  - `UP_DISCARDED`: no consent; the report is deleted without being sent.
  - `UP_CORRUPT`: bad checksum, magic or length, or larger than `max_message()`; the report is deleted and `reason`
    says why.
  - `UP_SEND_FAILED`: no peer, or the send queue was full; the report is kept for the next launch.
  - `UP_NONE`: no report, or an empty file.

  A newer crash replaces a report that was never sent.

### Crash report format

| field | size | notes |
|---|---:|---|
| magic | 4 | `4C 43 52 53` ("LCRS") |
| format | 2 | 1 |
| flags | 2 | 0 |
| ctx_len | 4 | bytes of the context fields that follow |
| install_id | 16 | |
| build_id_len, build_id | 1 + n | |
| tick | 8 | i64, at the last `arm` |
| session_ms | 4 | at the last `arm` |
| log_count, lines | 2 + Σ(2 + n) | oldest first, each `len u16` + UTF-8 |
| blackbox_len, blackbox | 4 + n | |
| reason_len, reason | 2 + n | UTF-8, ≤ 1024 bytes, e.g. `RuntimeError: memory access out of bounds` |
| frame_count | 2 | ≤ 64, innermost first |
| frames | | `func_index u32, offset u32, line u32, column u32, file_len u16, file, name_len u16, name` |
| checksum | 8 | FNV-1a 64 over every byte before it |

`offset` is the frame's byte offset in the module, as the browser prints it (`wasm-function[22]:0x476d`). A frame with
`line` 0 was not mapped. `scripts/telemetry_read.py --map app.wasm.map` maps such frames later, when the source map is
kept on the developer's side and not shipped.

Both formats start with a different magic, so a collector can receive batches and crash reports on one connection.

## Source maps for wasm

`build_wasm --debug line-tables` puts DWARF line tables in the module. `scripts/wasm_sourcemap.py` turns them into a Source
Map v3 file of the form browsers use for wasm: one generated line, where a segment's column is the byte offset in the
module. DWARF counts addresses from the start of the code section's body, so the script adds that offset. It then
removes the `.debug_*` sections (`llvm-objcopy --strip-debug`) and checks that the code section did not move. File names
under the repo are written relative to it, for example `app/crash_probe.mojo`.

Measured on `app/crash_probe.mojo` (`pixi run -e wasm test-telemetry`):

| | bytes |
|---|---:|
| module with line tables | 689,049 |
| the same module stripped (what ships) | 68,812 |
| its source map (4,225 line rows, 39 files) | 28,994 |
| a build without `--debug` | 67,969 |

The trap in that test is a load at address 2^40. The browser frame `wasm-function[22]:0x476d` maps to
`app/crash_probe.mojo:67:5`, which is the line marked `CRASH-LINE`.

The stripped module is **not** byte-identical to a build without `--debug`. Its code section is 51,499 bytes against
50,998, and it has one more function. So the map belongs to the stripped line-tables build, and a game that wants mapped
crash stacks ships that build. ludens-wasm-rt's `--debug` help says the code is byte-identical; on this module it is
not. That should be followed up in ludens-wasm-rt.

## Not built

- `app/main.mojo` does not record events, arm the crash context, or run `CrashUpload` yet. The demo game has no consent
  screen. The web shell's frame loop already calls `crash.capture`, which writes nothing until the module arms.
- HTTPS as a second way to send. Batches and reports are byte messages, so an HTTPS sink would POST the same bytes.
  The web host has no fetch import for that yet.
- Native stack traces and fault signal handlers.
- The collector, and any dashboard.

## Related issues

- **#149 (live operations):** the A/B bucket goes into the batch header with `set_tag`. Remote config and store events are
  game kinds (256 and up), or `EV_PURCHASE`.
- **#156 (bug reports, playtest analytics):** a playtest session is the batch stream of one `session_id` (`seq` 0, 1, ...).
  Heatmaps read the x, y, z values of `EV_DEATH` and of the game's position kinds. The bug report bundle can reuse the
  crash context (build id, last log lines, black box) and add a snapshot, a screenshot, settings and the tester's note.
