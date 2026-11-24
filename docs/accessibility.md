# Accessibility baseline (#118)

Engine-side switches a game exposes in its options screen: captions, text scale, camera shake and reduce motion, a flash limiter,
colour-blind filters, volume per audio bus and mono output. All of them are fields of one struct, `Access` (`game/access.mojo`),
saved in the player profile file with the input bindings.

| setting (`key value`) | values | default | what it does | code |
|---|---|---|---|---|
| `text_scale` | 100 .. 200 (percent) | 100 | font sizes of the HUD and widgets, through `UiEnv.text_scale` | `app/access_host.mojo` `ui_env`, `ui/scale.mojo` |
| `shake` | 0 .. 100 (percent) | 100 | scale of the camera shake | `game/camera_shake.mojo` |
| `reduce_motion` | on, off | off | shake 0; depth of field and motion blur get no blur circle and a closed shutter | `SceneRendererOf.reduce_motion` (`app/render3d.mojo`) |
| `flash_limit` | on, off | off | no pixel's luminance moves more than `flash_step` between two frames | `FlashLimit` (`app/access_post.mojo`) |
| `flash_step` | 1 .. 50 (percent) | 1 | luminance change allowed per 1/60 s; scaled by the frame time at other rates | `Access.flash_step_for` |
| `colorblind` | off, protanopia, deuteranopia, tritanopia | off | the colour-blind stage | `ColorBlind` (`app/access_post.mojo`) |
| `colorblind_mode` | correct, simulate | correct | correct: shift what the viewer confuses; simulate: show what such a viewer sees | |
| `colorblind_strength` | 0 .. 100 (percent) | 100 | blend with the unfiltered colour, in linear light | |
| `volume.master`, `.music`, `.sfx`, `.ambience`, `.ui`, `.voice` | 0 .. 100 (percent of amplitude) | 100 | the player's gain per bus, multiplied with the game's own dB and mute | `Mixer.set_user_volume` (`app/mixer.mojo`) |
| `mono` | on, off | off | left and right of the final mix both become their mean | `Mixer.set_mono` |
| `captions` | on, off | off | draw captions | `game/captions.mojo` |
| `caption_size` | 50 .. 200 (percent) | 100 | caption font size, times the text scale | |
| `caption_background` | 0 .. 100 (percent opacity) | 75 | the box behind a caption; 0 draws no box | |
| `caption_speaker` | on, off | on | the speaker's name before a line | |

A value outside its range, or a name that is not in the table, is refused with a message naming the key and the range; the
setting keeps its value.

## Where each piece sits

- `game/access.mojo`: `Access`, its ranges, `set(key, value)`, the profile rows, `post_user(dt)` (the numbers the post stages read).
- `app/access_host.mojo`: `AccessHost`, the one object `AppOf` (`app/main.mojo`) owns. Once per game frame `step` sends the volumes and
  mono to the mixer, ages the captions and decays the shake; `heard(event)` raises an event's caption; `camera(pose)` adds the shake
  to the view's camera (the game's own camera, state and hash do not read it); `ui_env(env)` puts the player's text scale into the
  `UiEnv` the game gets.
- `app/render3d.mojo`: `reduce_motion` makes the frame uniform carry blur circle 0 and shutter 0.
- `app/access_post.mojo`: the two stages and `comptime AccessPost = ThenPost[History[Stage[FlashLimit]], Stage[ColorBlind]]`. A game
  puts them in its pipeline (`AppOf[MyMode, DefaultPasses, AccessPost]`); the default pipeline of the demo game is still `NoPost`,
  so the demo's frames and goldens are unchanged. The stages cost a full-screen pass each plus History's copy of the frame whether
  or not a setting is on, so a game that offers neither switch leaves them out. `AppOf` sets `post_user` and `reduce_motion` on its
  renderer every frame; with `NoPost` they have no effect.
- `game/access_filters.mojo`: the colour-blind and flash-limiter arithmetic on the CPU (the reference the GPU stages are tested
  against) and `flash_count`, the measure the limiter is judged by.

## Profile file

`profile/actions.txt` (the name is from when it held only bindings) holds both:

```
ludens-profile 1
set jump.main key:KeyJ pad:b0 vpad:b0
access text_scale 150
access volume.music 40
access mono on
```

`access` rows are written only for settings that differ from their defaults, so a player who changed none has the file as
before this change. The input loader gets the text without the `access` rows (`without_access_rows`), the access loader only the
`access` rows (`Access.load_rows`); a row that cannot be applied is skipped and counted in `ProfileStore.problems`, the others still apply. A rebind
keeps the access rows and a settings change keeps the bindings (`ProfileStore.access_text`, appended by `save`).

## Captions

A track (`game/captions.mojo`), loaded with `app_captions_load` or `Captions.load`:

```
ludens-captions 1
caption cue1 duration=1200 speaker=who.ball text=cap.jump
text en who.ball Ball
text en cap.jump jumps
text zh-TW cap.jump 跳起來
```

`caption <event>` names a mixer event (the demo game's sounds are `cue1`, `cue2`); when the mixer starts it, the caption is
shown for `duration` milliseconds. A repeating sound restarts its caption instead of stacking one; at most 3 are up, the oldest
leaving first. Dialogue has no event: `Captions.say(speaker, text, ms)` or `window.game.say(speaker, line, ms)`. Strings are
looked up in the current locale (the UI locale index of `UiEnv`), then the first locale of the file, then the key.

Drawing: from the bottom of the safe area upward, centred, each in a box that holds its wrapped text. Font size is 18 reference
pixels times the window factor, `caption_size` and the UI text scale; text is wrapped to the safe width, so 200 % x 200 % stays
inside it (tested at 640 x 360 with insets).

## Camera shake

`CameraShake.add(trauma)` from a hit (0 .. 1, capped), `step(dt)` per frame (trauma falls 1.5 per second), `apply(pose, scale)` moves
the camera along its own right and up axes by `0.3 m * trauma^2 * scale * noise`, noise in [-1, 1] from an integer hash of (seed,
frame, axis): the same calls give the same offsets. `scale` is `Access.shake_factor()`, 0 with reduce motion. At scale 0 the pose
comes back bit for bit. The host exposes `app_shake(trauma)` and `window.game.shake(trauma)`; nothing in the demo game raises trauma
(game feel, #143, decides when a game does).

## Flash limiter

Per pixel, the stage keeps the colour from the line between last frame's output and this frame's input whose luminance
(0.2126 R + 0.7152 G + 0.0722 B of the encoded values) is at most `step` from last frame's. Frame 0 and step 0 pass the input
through. Because the limit is a rate (percent per 1/60 s, scaled by the frame time), a flicker faster than 3 flashes a second
cannot swing the luminance by 10 %: at 1 % per 1/60 s, 9 frames move at most 9 %. The cost is that a cut from white to black takes
100 frames at 60 fps (1.7 s) to complete while the limiter is on. That is the trade of the switch, and why it is off by default.

`flash_count(series, 0.1, fps)` (game/access_filters.mojo) counts flashes the way the web accessibility guideline words it: a
change is a swing of at least 10 % of full luminance from the last turning point, two opposite changes are one flash, and the
largest count in any one-second window is reported (more than 3 fails).

Not measured here: area. The guideline counts only flashes that cover a certain fraction of the screen and has a separate rule for
saturated red; the limiter applies to every pixel regardless, which is stricter than the guideline for small flashes and does not
single out red.

## Colour-blind stage

Simulation: Machado, Oliveira and Fernandes (2009), severity 1.0, 3 x 3 matrices on linear RGB (each row sums to 1, so greys stay
grey). Correction: the classic daltonization heuristic (simulation error moved into the channels the viewer can use; protanopia
and deuteranopia: red error into green and blue; tritanopia: blue error into red and green). It increases the difference between
colours a viewer confuses; it is not a clinical correction and does not model anomalous trichromacy below severity 1.0 (use
`colorblind_strength` to blend).

## `window.game` and exports

| call | export |
|---|---|
| `access("text_scale 150")`, `accessText()`, `resetAccess()` | `app_access_set`, `app_access_text`, `app_access_reset` |
| `captionsLoad(track)`, `say(speaker, line, ms)`, `captions()` | `app_captions_load`, `app_caption_say`, `app_captions_state` |
| `shake(trauma)`, `shakeOffset()` | `app_shake`, `app_shake_offset` |

The page changes settings only through `access`; the demo page has no options screen (a game builds its own).

## Checks

| task | in CI | what it checks |
|---|---|---|
| `test-access` | editor workflow | settings, ranges, profile rows (`tests/access.mojo`); camera shake, captions, colour-blind matrices against published values and invariants, flash limiter and `flash_count` on a synthetic flashing scene; the host's wiring: text scale into the demo HUD (16, 24, 32 px at 100, 150, 200 %), volumes and mono into the mixer, events into captions (`tests/access_app.mojo`) |
| `test-access-gpu` | parity workflow (lavapipe) | the two stages and the reduce-motion flag on the GPU, pixel by pixel against the CPU model (`tests/access_native.mojo`) |
| `test-access-app` | editor workflow | the wasm64 app under node: settings, the profile file restored by a second instance, captions from the jump's event, shake scale, master and music volume in the mixed audio (`tests/test_access.mjs`) |
| `test-audio` | editor workflow | `tests/audio_mixer.mojo`: user volume per bus and mono on a clip with 0.8 left and 0.2 right |
| `mutation-access` | no: about 30 builds, 6 to 15 minutes | one deliberate change at a time to the sources above; the covering test must fail |

## Not done here

- No options screen, and the demo game does not raise camera trauma or use `AccessPost`: both are a game's to wire.
- Subtitles follow audio events and dialogue lines a game gives; there is no timing track synchronised to a voice clip's samples.
- A mono check in the app under node cannot show the fold (the demo's jump and music are centred before mono); it is the mixer's native test that does.
- Flash area and saturated-red rules; screen-reader text; high-contrast themes; input timing assists (hold-to-toggle) are not part of the acceptance list.
