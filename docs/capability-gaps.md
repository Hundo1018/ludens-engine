# Capability gaps against game production (2026-11-22)

What a team making a game needs from an engine, taken from two public skill sets written for AI agents that make
games, compared with what this ecosystem (ludens-core, ludens-engine, ludens-playground, ludens-wasm-rt, wgpu-mojo,
miniaudio-mojo) provides today. The result is a ranked list of missing capabilities, each with an issue.

## Sources and method

- [claude-code-game-studios](https://github.com/Donchitos/Claude-Code-Game-Studios) at `abc0de7`: 49 agents, 78
  skills, templates and rules, following concept → systems design → technical setup → pre-production → production →
  polish → release.
- [awesome-gamedev-agent-skills](https://github.com/gamedev-skills/awesome-gamedev-agent-skills) at `c6ca6c4`: 78
  skills (15 disciplines, 9 genres, 5 workflows, per-engine skills) and a router.

Every skill and agent definition was read. For each production stage the engine-side features the work depends on
were listed, with the files they come from. Importance: **H** = in both sets and either in three or more files or
gated (a launch or certification item, "blocking"); **M** = once in both sets, or several files in one; **L** = one
file. Process work that needs no engine feature (sprint planning, design reviews, changelogs) is left out.

Our side was read from `main` of each repository (ludens-core `c8a956b`, ludens-engine `06c79b4`, ludens-playground
`9e6fc24`). Maturity: **L1** shipped on a published web build, **L2** used natively or by a consumer's tests, **L3**
tested inside its own repository only, **L4** planned with an issue, **L5** absent.

## The ten most emphasized capabilities

| # | capability | imp. | here | gap | issue |
|---|---|---|---|---|---|
| 1 | A scriptable game hook: read state, inject input, step without drawing, start in a scene with a seed | H | L2: `scripts/game_node.mjs` drives the app through `app_input` / `app_frame` | contract published (`docs/automation.md`); playground's modes still need `state()` / `reset()` | #115 |
| 2 | Determinism: same seed and input give the same hash; find the tick where two runs diverge | H | L1: golden, parity gates, fp / FMA probes | `scripts/divergence.py` prints the first differing tick and keys; tested | #115 |
| 3 | Batch simulation over many seeds or levels (balance tables, solvers) | H | L3: headless `EmbedWorld` | `ludens sim` runs the demo game; other games add an entry (`docs/automation.md`) | #115 |
| 4 | Data tables with a validated schema, and a live tuning panel | H | L2: `editor/cvar.mojo` (native); core `ecs/schema` numeric only | built in #119: `docs/data-tables.md` | #119 |
| 5 | Save games: versioned with migrations, atomic, slots, corruption handling | H | L2: `platform/save_store.mojo` (versions, migrations, checksum, two-file write, slots, profile), the demo game saves and restores (#122) | `docs/save-games.md`; no menu or key in the web shell calls it yet | #122 |
| 6 | Profiler with per-subsystem budgets, p95 / p99, draw calls, CI gates | H | L2/L3: `diag/` trace and counters, `icount`, benchmark report; per-segment timers, counters, overlay, trace, `budgets.toml` gate (`docs/frame-budgets.md`) | GPU timing is native only; no shadow / post draw counts; no AI subsystem to time | #123 |
| 7 | Input actions by intent, rebinding, analog axes, device prompts | H | L1: action map asset, analog sticks, rebinding saved to a profile, input buffer, prompts (`docs/input.md`) | no contexts, swap on conflict or rebinding screen; HUD hint not yet from prompts | #117 |
| 8 | UI: scaling and safe area, gamepad focus, screen stack, data binding | H | L1: `ui/` layout, focus, gestures | SDF font with 5984 glyphs incl. Traditional Chinese, reference-resolution scale, text scale to 200 %, safe-area insets (#116); the 5 x 7 `ui/font.mojo` remains; no screen stack or data binding | #116, #17 |
| 9 | Localization: string tables, plurals, font coverage, RTL | H | L1: `ui/loc.mojo` string tables (fallback chain, plurals for 4 rule families, pseudo-localization, glyph check); L3: core `gameplay/loc_keys` (ids only) | RTL shaping, plural categories zero / two, gender agreement not handled (follow-up) | #116 |
| 10 | Audio: events, buses with ducking, adaptive music, 3D attenuation | H | L1: `app/mixer.mojo` (events with seeded clip / pitch / volume, 6 buses with dB and mute, sidechain ducking, music layers changed on the bar line, a miniaudio `Spatializer` per positioned voice, BS.1770 LUFS), `docs/audio.md` | occlusion, reverb and HRTF (#137); music streams are PCM in memory (#142); no event editor | #120 |

Next in emphasis: **accessibility** (H in one set, M in the other; built in #118: `docs/accessibility.md`), a **dialogue graph
with a validator** (core `gameplay/dialogue` is L3 with no asset format or validator), **networking with a real
server** (in-page rollback and prediction are L1; no remote server, matchmaking or relay), **telemetry and crash
reporting** (built in #147: `docs/telemetry.md`; the demo game does not use it yet), and **particles** (built in #121: `docs/particles.md`).

## Domains that were never in focus

1. **Text and localization.** No vector font, so no text beyond ASCII capitals: the first wall a game in Chinese hits.
2. **Player settings and accessibility.** Rebinding, captions, text scale, volume per bus: release checklist items in
   both sets, none present.
3. **An automation contract for agents and QA.** Determinism is strong here, but it is not exposed as an interface a
   test or an agent can drive (#115).
4. **Content as data.** Tables, schemas and tuning, which the scene format's schema (§8 of `docs/scene-format.md`)
   needs anyway (#119).
5. **Common rendering features.** Particles are built (#121, `docs/particles.md`); anti-aliasing, bloom and colour grading are built (#139,
   `docs/rendering-tier1.md`); terrain, decals and trails are built (#140, `docs/rendering-tier2.md`); 53 style
   pipelines exist.

## Where the investment runs ahead of the need

Physics is far broader than either skill set asks for. Their physics requirements are a fixed tick with
interpolation, CCD, collision layers, sleeping and ray / shape casts, all present. ludens-core also has fluids, FEM,
vehicles and combustion, but by its own table (17.97) 15 of 33 game-relevant features are reachable through
`EmbedWorld` and 14 through the C-ABI, so most of that breadth is out of a game host's reach today. The gaps above
are worth closing before more simulation breadth.

## Order

| priority | issue | depends on |
|---:|---|---|
| 1 | #115 E21 automation contract: game hook, divergence trace, batch runner | — |
| 2 | #116 E22 text: SDF font atlas with CJK, UI scaling, localized string tables | #17 |
| 3 | #117 E23 input action map and rebinding | wgpu-mojo #29 |
| 3 | #118 E24 accessibility baseline | #116, #117, #120 |
| 4 | #119 E25 data tables with a schema, live tuning panel | #9 (schema, §8) |
| 5 | #120 E26 audio buses, music, 3D | — |
| 6 | #121 E27 particles and VFX | — |
| 7 | #122 E28 save games | — |
| 7 | #123 E29 frame budgets and CI gates | #115 (scripted scene) |

## Rendering and audio beyond the top ten (2026-11-23)

Rendering and media features that had no issue, found by searching `app/`, `game/`, `ui/` and `docs/`. Put on the
roadmap on 2026-11-23 in this order; none is built. The tiers rank how many games need a feature against its cost.

| tier | issue | features | today |
|---:|---|---|---|
| 1 | #139 | anti-aliasing (MSAA, FXAA, TAA after measuring), bloom, colour-grading LUT | built: MSAA 4x, FXAA, bloom, LUT (`docs/rendering-tier1.md`); TAA measured, not built |
| 2 | #140 | terrain renderer, decals, trails and ribbons | built: chunked LOD terrain from the collider's heights with splat map, projected decals with a budget, trails (`docs/rendering-tier2.md`) |
| 3 | #141 | mesh LOD, volumetric fog / clouds / light shafts, global illumination | built: mesh LOD, froxel volumetric fog with light shafts, baked irradiance probes (`docs/rendering-tier3.md`); clouds and dynamic GI not built |
| 4 | #142 | video playback, audio streaming and compressed formats, voice chat | clips are PCM in memory; miniaudio-mojo's decoders are bound but unused |

Related, already planned: particles #121, audio events / buses / music / 3D #120, spatial audio beyond it #137,
water / reflections / ray tracing #138, device seams #135.

## Gameplay support (2026-11-23)

ludens-core already has most gameplay systems: abilities, combat and a hit pipeline, inventory, objectives, dialogue,
level flow, checkpoints, saves, a camera rig, characters, vehicles, rule tables, achievements, balance, and AI
(behaviour trees, GOAP, EQS, perception, steering, influence maps). Most of them are not exposed to a host: the
exposure list (core ROADMAP 17.101, Hundo1018/ludens-core#159) marks them pending. That is the largest gameplay gap.
The items below are absent everywhere and had no issue. Put on the roadmap on 2026-11-23; #146 and #147 are built (2026-11-25),
the others are not.

| issue | what |
|---|---|
| #143 | game feel: hitstop, time scale, screen shake, rumble timing (deterministic under replay) |
| #144 | object pools and runtime spawning of prefabs (generational handles, capacity, deterministic order) |
| #145 | difficulty and assist modes, tutorials and hints, dialogue graph validator |
| #146 | in-game console and cheats (debug builds), photo mode: built, `docs/console.md` |
| #147 | telemetry and crash reporting (opt-in; core `diag/outbox` and `gameplay/blackbox` get a transport): built, `docs/telemetry.md` |
| #148 | mod support: wasm mods in a checked instance, a narrow versioned mod API |
| #149 | live operations, monetization (store seam, receipts verified by a backend) and anti-cheat |

Development tooling gaps (wasm crash symbolication, project template, API docs for game developers, multiplayer test
harness, wasm memory profiling, store release pipelines, a Windows shell, a scripting layer, asset licence tracking)
were listed the same day and deliberately left off the roadmap for now.

## Assets and production flow (2026-11-23)

Assets today: converters for glb meshes, skins and clips, textures and wav (`scripts/assets/`), read through
`app/assets.mojo`. Already planned: the asset database #12, textures and materials #16, packing #15, hot reload #14,
fonts #116, data tables #119, automation and batch runs #115, frame budgets #123, scene merging #125, Android
packaging #22 and #23. The items below had no issue. Put on the roadmap on 2026-11-23; none is built. Version control
for large binary files (LFS policy, asset locking) was considered and left off.

| issue | area | what |
|---|---|---|
| #150 | assets | 2D editor tools: tile painter (depends on the editor #10 and on #191) |
| #191 | assets | 2D runtime: sprites, sprite sheets, tilemaps, atlas, a 2D render path, draw layers separate from z (nothing 2D exists today; split from #150 on 2026-11-25, no editor dependency) |
| #151 | assets | animation retargeting between skeletons |
| #152 | assets | material graph editor, compiling to the existing material interface |
| #153 | assets | FBX import and DCC exporters, import validation rules, per-platform variants |
| #154 | assets | asynchronous streaming of meshes, textures and audio at run time |
| #155 | assets | starter asset pack for prototyping (CC0 or own work) |
| #156 | flow | one-key bug report with replay and state; playtest analytics and heatmaps |
| #157 | flow | level blockout (greybox) tools |
| #158 | flow | localization workflow: export, import, missing / stale / overflow checks, pseudo-locale |
| #159 | flow | compliance checklists: platform requirements, age ratings, privacy inventory, accessibility |
| #160 | flow | release pipeline: game versions, player changelog, store submission |

## Narrative (2026-11-23)

ludens-core already runs narrative: dialogue graphs with flag conditions and effects (`gameplay/dialogue`), world flags
and a state stack (`gameplay/flow`), event-driven objectives (`gameplay/objectives`), level transitions (`gameplay/level_flow`), timeline playback
(`gameplay/sequence_player`), checkpoints that carry all of it (`gameplay/checkpoint`) and localization keys
(`gameplay/loc_keys`). None is exposed
to a host yet (Hundo1018/ludens-core#159). The dialogue validator is #145. The items below had no issue. Put on the
roadmap on 2026-11-23; none is built.

| issue | what |
|---|---|
| #161 | a writing format for dialogue and quests; Ink / Yarn / Twine import |
| #162 | dialogue and quest graph editor with in-editor preview |
| #163 | quest structure: stages, failure, timers, exclusive branches, journal |
| #164 | barks: contextual one-liners with priority, cooldown, repetition limits |
| #165 | staging cues in dialogue (camera, animation, audio, cutscenes) through core `gameplay/sequence_player`; skip = play-through |
| #166 | voice-over timing and lip sync |
| #167 | text effects, markup and variables in lines |
| #168 | relationships, affinity and reputation |
| #169 | automated branch coverage of dialogue and quests |
| #170 | storylets: quality-based, systemic narrative (lowest priority) |

## Limits of this comparison

- Both skill sets target mainstream engines (Godot, Unity, Unreal, three.js, Roblox) and a web scaffold of their own;
  their emphasis reflects what agents need to drive those, which overweights automation and checklists.
- Gaps the sets themselves admit and that are not ranked here: modding / user content, cutscene sequencing, anti-cheat,
  backend operations and matchmaking, an animation retargeting pipeline, voice chat, haptics.
- Importance is a count of mentions and gates, not a measurement of how often a shipped game uses a feature.
