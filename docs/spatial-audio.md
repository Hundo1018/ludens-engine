# Spatial audio (planned, issue #137, a sub-issue of #120)

Not built. Decided 2026-11-23: on the roadmap now, built later. This note records what each layer already offers,
what the engine lacks, and the phases.

#120 (E26, `docs/capability-gaps.md`) already asks for the basic 3D part: a listener on the camera and positioned
emitters with attenuation and panning through the spatializer. Phase 1 below is that item. #137 adds occlusion,
reverb zones, HRTF and impact sounds at core's contact positions.

## What exists

- **miniaudio-mojo** wraps miniaudio's standalone 3D DSP in `src/miniaudio/spatializer.mojo`:
  - `SpatializerListener`: position, facing, world up, velocity, cone, speed of sound.
  - `Spatializer`: position, direction, velocity, attenuation model with distance and gain limits and rolloff, cone,
    doppler, master volume.

  Bindings and API have tests, and the library builds for wasm. It does distance attenuation, panning and doppler. It
  has no HRTF, so it cannot place a sound in front of, behind, above or below the listener.
- **ludens-core:**
  - Contact events carry position and impulse (C-ABI 0.6), so impact sounds have a place.
  - World ray queries can test occlusion.
- **This engine:**
  - `GameMode.cues()` returns cue numbers and `sounds()` returns stereo clips.
  - `app/sim.mojo` mixes through miniaudio's `Scene`.

  Mixing runs inside the wasm module, so web and native hear the same result.

## What is missing

- **Cue position:** cues carry no position, so every sound plays non-spatially.
- **Listener:** it does not follow the camera.
- **Spatializer:** the mixer does not use it.
- **Occlusion and reverb:** there is neither.

## Phases

1. **Positioned cues** (#120's 3D item).
   - A cue carries position, velocity and gain.
   - Each playing voice gets a `Spatializer`.
   - The listener is set from the camera every frame.
   - Impact sounds take the position of core's contact events.
2. **Occlusion.** A ray from the listener to the source through core's world query. When it is blocked, gain drops and
   a low-pass filter is applied.
3. **Reverb zones.** Reverb per room or area, built from miniaudio's delay and filter nodes.
4. **HRTF**, for headphones. Two options:
   - our own convolution in wasm with a public HRTF set (SOFA format);
   - a binding to Steam Audio or Resonance Audio (both Apache-2.0 C libraries that can be built to wasm).

   Measure CPU cost against the number of voices.

## Acceptance

- **Phase 1:** a test places a source to the left, to the right and behind the listener, at 1, 10 and 100 m, and
  checks gain and pan against the attenuation model.
- **Phase 2:** a wall between source and listener lowers the gain and cuts high frequencies. Removing the wall
  restores both.
- **Every phase:**
  - the audio output is bit-identical between the native and wasm builds for the same input;
  - the per-frame mixing cost is reported for N voices.
