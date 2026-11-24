# assets/audio/

Music loops in the engine's `.lsound` format (48 kHz, mono, 16-bit; `scripts/assets/convert_wav.py` describes it) and the track
list `music.music` that the audio mixer reads (`app/audio_assets.mojo`, `docs/audio.md`).

| File | What | Length | License |
|---|---|---|---|
| `calm_pad.lsound` | A minor chord pad, one slow swell per loop | 2 bars at 120 bpm, 4 s | MIT, `LICENSE.txt` |
| `calm_perc.lsound` | A kick on every beat, a noise tick on every off-beat | 2 bars, 4 s | MIT, `LICENSE.txt` |
| `tense_pad.lsound` | A minor second cluster pad | 2 bars, 4 s | MIT, `LICENSE.txt` |
| `music.music` | Two tracks: `calm` (pad + perc layers), `tense` (one layer) | text | MIT, `LICENSE.txt` |

All of it is computed by `scripts/assets/gen_audio.py` (no recording is used), so the license is the repository's. The
bytes are the same on every platform (integer and + - * / arithmetic only); `pixi run -e wasm test-audio-assets` regenerates
them and compares. `LICENSE.txt` is copied to the web build as `audio-LICENSE.txt` next to the clips
(`scripts/build_web.py`), the way `font-LICENSE.txt` travels with the font.

A recorded or third-party clip added here needs its license text and source recorded in this table first, and that license
must allow redistribution in a web build; `scripts/check_audio_asset.py` fails the build if a built site has audio without
`audio-LICENSE.txt`.
