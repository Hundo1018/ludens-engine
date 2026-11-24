# Audio mixer (issue #120, E26)

`app/mixer.mojo` mixes everything the game and the shell play: events, buses, the sidechain, music, positioned voices
and the master loudness meter. `Sim.render_audio` adds its output to the contact tone, and `app_audio_render` hands the
result to the AudioWorklet. Everything on the render path is `+ - * /`, comparisons and miniaudio's spatializer (C, built
into the same wasm module), so the web and native builds give the same bytes. Occlusion, reverb and HRTF are not here
(#137, `docs/spatial-audio.md`).

| Module | What |
|---|---|
| `app/audio_event.mojo` | The event asset: text format, parser with line-numbered errors, bus ids. |
| `app/audio_math.mojo` | `db_to_gain` (no libm), `Rng` (xorshift64*, integer). |
| `app/mixer.mojo` | `Mixer`: clips, events, voices, buses, ducking, listener, rendering. |
| `app/music.mojo` | `Music`: tracks of layers, loop, changes quantized to the bar. |
| `app/loudness.mojo` | `LoudnessMeter`: BS.1770-4 K-weighting, momentary and integrated LUFS. |
| `app/audio_assets.mojo` | `.lsound` decoding and the track list format. |
| `game/cue.mojo` | `SoundCue`: a cue with a position, what `GameMode.positioned_cues()` returns. |

## Events

An event asset names several clips, a bus, pitch and volume ranges, a priority and a concurrency limit:

```
event cue2
  clips cue2 cue2b        # clip names; a game's own clips are cue1, cue2, ... (GameMode.sounds)
  bus sfx                 # music sfx ambience ui voice (master is the final mix: the parser refuses it)
  pitch 0.8 1.25          # playback rate, linear interpolation
  volume -4 0             # dB added to the bus gain
  priority 2
  limit 4                 # voices of this event at once
  spatial 1
  min_distance 6          # full gain inside this radius (m)
  max_distance 60
```

Each play draws the clip, the pitch and the volume, in that order, from the mixer's seeded `Rng` (`app_configure(seed, ...)`
reseeds it), so the same seed and the same calls give the same bytes. At the limit, the oldest voice of the event is
replaced when the new play's priority is equal or higher; a lower priority is dropped and counted (`Mixer.dropped`). With
all 24 voices busy, the lowest-priority, oldest voice is the candidate under the same rule.

## Buses and ducking

Six buses (Master, Music, Sfx, Ambience, Ui, Voice) have a volume in dB and a mute (`app_set_bus`; `stats.setBus` in the
page). That call is what the accessibility menu of E24 (#118) sets. One sidechain: while the Voice bus (before its fader) is
above a threshold, the Music bus is pulled down by 12 dB, with a 10 ms attack and a 250 ms release by default
(`Mixer.set_ducking`). The level detector and the gain follower are per-sample one-pole filters, so the result does not
depend on how the output is cut into blocks (`tests/audio_mixer.mojo` renders 128, 37 and 40000-frame blocks and compares bytes).

## 3D (phase 1 of `docs/spatial-audio.md`)

- **Listener.** `_step_mode` in `app/main.mojo` sets it from `GameMode.camera()` every frame: the camera's position, its
  forward axis (`CameraPose.forward()`) and its up axis.
- **Positioned cues.** `GameMode.positioned_cues()` returns `SoundCue` values (cue number, x, y, z, gain in dB, whether to
  log it). The demo game raises its jump at the ball and an impact at every contact that begins with an impulse above 0.4
  (EVENT_BEGAN in `tick_events`, the contact point from ludens-core, -30 dB at that impulse, 0 dB at 8, at most 4 per
  frame, none in the first 30 ticks while bodies settle).
- **Spatializer per voice.** A spatial voice owns a miniaudio `Spatializer` (1 channel in, 2 out): inverse attenuation
  between `min_distance` and `max_distance`, rolloff 1, panning from the direction in the listener's frame. The clip is
  averaged to mono before it goes in. `Mixer.move_voice` moves a playing voice.
- **Velocity.** A cue carries the source's velocity (the demo's jump carries the ball's). Each block the mixer shifts the voice's
  playback rate by the Doppler factor `c / (c - v)`, `v` the speed toward the listener, `c = 343.3 m/s`, `v` capped at 0.9 c; the
  listener is taken as still. miniaudio's standalone `Spatializer.process` computes a Doppler pitch but does not resample, and
  the wrapper does not expose it, so the mixer computes it and applies it in its own resampler, multiplied with the event's
  pitch. The velocity is also set on the voice's `Spatializer`.
- **What it does not do.** Without HRTF a source ahead and a source behind give identical gains. This is documented in
  `docs/spatial-audio.md` and measured in `tests/audio_mixer.mojo`.

The gain model, as measured (constant 0.5 input, 1 m minimum distance, listener facing -Z):

| Source | Left ear | Right ear |
|---|---|---|
| left, d m | 1 / d | 0.2 / d |
| right, d m | 0.2 / d | 1 / d |
| ahead or behind, d m | 0.5 / d | 0.5 / d |

## Music

A track is a tempo, a bar length in beats, and a clip per layer, all layers the same length. `music.music` lists them
(`assets/audio/`). A request to change track or to switch a layer is applied at the next bar line of the playback position, at
that exact frame inside a block. A bar is `round(60 / bpm * beats * rate)` frames, an integer. The new track continues at the
same offset inside its loop. Clips are held in memory as PCM; streaming from compressed files is #142.

## Loudness

`LoudnessMeter` follows ITU-R BS.1770-4 at 48 kHz: the published K-weighting coefficients, 400 ms windows every 100 ms, the
-70 LUFS absolute gate and the -10 LU relative gate. `stats.loudness(0)` is the momentary value and `stats.loudness(1)` the
integrated value, in the page console. The test is EBU Tech 3341's first case: a stereo 997 Hz sine at -23 dBFS reads -23.0 LUFS.

## Files and the web build

`assets/audio/` holds three synthesized loops, `music.music` and `LICENSE.txt` (MIT, the repository's license; nothing is
sampled). `scripts/build_web.py` copies them to `build/web/audio/` with `index.txt` and writes `audio-LICENSE.txt` beside
them, and `scripts/check_audio_asset.py --built` fails the build if audio ships without it. The page loads them for the
game (not for `?demo` or `?selftest`) through `app_load_audio`; `?nomusic` skips starting the music.

## Checks

| Command | What |
|---|---|
| `pixi run -e wasm test-audio` | `tests/audio_mixer.mojo`: each behavior against a worked value. |
| `pixi run -e wasm audio-same` | Native and wasm64 give the same hash for every output sample of three scripted renders. |
| `pixi run -e wasm test-audio-assets` | The committed files equal a fresh synthesis; the license is in them and in a built site. |
| `pixi run -e wasm test-audio-app` | The shipped files through `app_load_audio` in the real app, under node. |
| `pixi run -e wasm audio-bench` | Mixing cost per 128-frame block for N voices, native and wasm64 (a report, not a gate: CI timing is noisy). |
| `pixi run -e wasm python3 scripts/mutate_audio.py` | Applies one breaking change at a time and expects a test to fail (slow; not in CI). |

## A native build detail

miniaudio's `ma_rsqrtf` is the x86 `rsqrtss` instruction, an approximation whose result differs between CPU models, and the
spatializer normalizes every direction with it. The wasm build computes `1 / sqrt(x)`. With the stock shim the native and wasm64
3D output differed (a source 7 m behind gave 0.035723 natively, 0.035714 in wasm64 and in the model). `scripts/native_libs.py`
now builds the native shim with `-DMA_NO_SSE2`, which makes miniaudio use `1 / sqrt(x)` too. The existing PCM hash of
`pixi run -e wasm parity` is the same with and without the flag (1117392856119928307).
