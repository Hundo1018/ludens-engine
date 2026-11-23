# Save games (issue #122)

A game saves data (seed, scene, counters, body poses), not objects. The engine provides the container: slots, an
autosave slot, a profile kept apart from run saves, a version per save with a stepwise migration chain, a checksum, and a
two-file write that leaves the previous save loadable. Code: `platform/save_store.mojo` (format and store, standard
library only), `platform/file_cloud_save.mojo` (native files), `app/os_cloud_save.mojo` (browser storage through
`os_file_*`). The game's side is three `GameMode` methods (`game/mode.mojo`): `save_version`, `save_state`, `load_state`.

## File format

All integers little-endian. 30 header bytes, then the payload.

| offset | size | field |
|---:|---:|---|
| 0 | 4 | magic `4C 53 56 45` |
| 4 | 2 | `format`: the container layout, `SAVE_FORMAT = 1` |
| 6 | 4 | `version`: the game's payload version, 1 or more |
| 10 | 8 | `generation`: counts the writes to the slot, starts at 1 |
| 18 | 4 | payload length |
| 22 | 8 | `checksum`: FNV-1a 64 over bytes 0-21 and the payload |
| 30 | n | payload |

## Version field and loading older saves

`version` is the game's. A build declares its current version (`GameMode.save_version`). A load returns the stored version:

- stored = current: `SAVE_OK`.
- stored < current: `SAVE_NEEDS_MIGRATION`. The game passes the payload through `migrate_payload(migrator, payload, stored,
  current)`, which calls the game's `Migrator.migrate(v, payload)` for v = stored, stored + 1, ..., current - 1. A missing
  step raises `save: no migration from version v to v+1`. Tested: a version 1 payload `[42]` becomes `[42, 3]` at version 2
  and `[42, 3, 7]` at version 3 (`tests/platform_save.mojo`).
- stored > current: `SAVE_NEWER`, no payload, the message `save version 5 is newer than this build (4); update the game to
  load it`. The slot is not marked writable, so this build cannot overwrite that save. A `format` greater than `SAVE_FORMAT`
  is refused the same way.

Versions of `format` (the container) and `version` (the payload) are separate: changing the header layout raises `format`,
changing what a game stores raises `version`.

## Corrupt or truncated files

A file is corrupt when: it is shorter than 30 bytes, the magic is wrong, the length is not 30 plus the payload length (cut short
or extended), or the checksum does not match. Each case has its own message (`truncated: 10 bytes, the header alone is 30`,
`not a save file (bad magic)`, `truncated or extended: ...`, `checksum mismatch`). The loader never returns a corrupt
payload, and never throws away a file.

- One file corrupt, the other valid: `SAVE_BACKUP_OFFERED`. The event carries the other file's payload, its version and
  generation, and a message naming the bad file and the fault. Nothing applies the backup by itself: the caller shows the
  message and decides.
- No valid file and at least one corrupt: `SAVE_CORRUPT`, no payload. The next save writes both files, so no corrupt file
  stays behind.
- Neither file exists: `SAVE_NOT_FOUND`.
- Storage returns an error for a read: that file counts as corrupt with the message `the storage could not read it`.
- Storage reports a failed write: `SAVE_WRITE_FAILED`, and the slot must be loaded again before the next save.

## Atomic write and backup

`os_file_*` has write and read only, no rename or delete. A slot is therefore two files, `<key>.0` and `<key>.1`, and a
save writes the file that does not hold the newest generation. A write that is cut off damages only that file; the other
holds the previous save, complete. A load reads both and takes the valid one with the higher generation. Tested by cutting
a write at every length from 0 to 33 bytes of a 34-byte file: the previous generation is offered each time.

A slot must be loaded before it is saved (`SaveStore.save` returns -1 and sets `last_error` otherwise), because the store
needs to know which file is free. Loading a slot first is also how a game lists its slots.

## Slots, autosave, profile

| API | key | files |
|---|---|---|
| `begin_load(slot, v)` / `save(slot, v, bytes)` | `run/<slot>` | `run/<slot>.0`, `run/<slot>.1` |
| `autosave(v, bytes)` | `run/auto` (`AUTOSAVE_SLOT`) | `run/auto.0`, `run/auto.1` |
| `begin_load_profile(v)` / `save_profile(v, bytes)` | `profile` | `profile.0`, `profile.1` |

Slot names are 1-32 of `A-Z a-z 0-9 - _`. The profile (settings, unlocks) is a separate slot with its own version and
generation: a corrupt run slot does not touch it (tested). Call `autosave` at a safe point, between ticks and not inside one.

## Storage backends

| backend | where | notes |
|---|---|---|
| `MemoryCloudSave` | tests | in memory |
| `FileCloudSave(root)` | native | files under `root`; the write is done when the request returns |
| `OsCloudSave` | web (`app/os_cloud_save.mojo`) | `saves/<key>` in the origin-private file system. `os_file_write` sends no result, so the write ack means "queued", not "stored". `os_poll` is the host's one result queue: a clipboard packet seen by this backend is dropped and counted (`foreign()`) |

## The demo game

`DemoMode.save_state` version 1: seed u64, scene name (length u8 and bytes), yaw (Float64 bits) u64, tick u64, jumps u64,
paused u8, then the `EmbedWorld.save` blob. `load_state` parses everything, rebuilds the scene for the seed and name, loads
the world over it, then sets the counters. Tuned values (`game/data/demo.table`) are settings and are not saved.
`tests/game_save.mojo` saves at frame 90, 150, 205 (paused) and 60 (scene `bare`), loads into a new `DemoMode` through a
`SaveStore` that was reset with `forget()`, plays the remaining frames and compares `hash()` and `state()` with the
uninterrupted run.

## Not done here

- No key or menu in the web shell saves or loads the demo: `shell/web/app.ts` and `game/demo_mode.mojo`'s intents are
  shared with other work. The API is what a shell or a game's menu calls.
- Two devices writing one slot (a cloud save conflict) is still open (`docs/platform.md`).
- No encryption or signing: the checksum detects damage, not tampering.
- The profile has no migration example beyond the shared chain; it uses the same `Migrator` mechanism.
