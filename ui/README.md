# ui/

Shared UI toolkit for the game and the editor (ludens-engine #17).

| Module | What |
|---|---|
| `geom.mojo` | `Rect`, `Insets` |
| `layout.mojo` | Flex-style rows and columns: fixed size, grow, shrink, padding, gap, align, justify; measure + arrange |
| `focus.mojo` | Directional focus navigation (arrow keys, d-pad, swipe) with Android's weighted distance, optional wrap |
| `draw.mojo` | The draw list: fill, stroke, text run, clip push / pop. No GPU object and no font; `DrawList.hash()` covers every field of every command |
| `immediate.mojo` | Immediate-mode widgets (`button`, `checkbox`, `slider`, `label`) on a `Ui`: pointer clicks (press and release on the same widget), Enter / Space, arrow-key focus movement with Android's rule, sliders keep Left / Right, disabled widgets, a `Theme` |
| `sdf_font.mojo` | SDF font (`.lfont` from `scripts/assets/convert_font.py`): glyph lookup, wrapping with real advances, glyph quads, a missing glyph draws a box and is counted, a software rasteriser with the fragment shader's arithmetic. `FontMetrics` is the atlas-free part a game can hold |
| `scale.mojo` | `UiScale` (reference resolution, text scale 0.5 to 2, safe-area insets) and `UiEnv` (what the host tells a game) |
| `loc.mojo` | `Localizer` / `StringTable`: dot-keys with context and maximum length, fallback chain, plurals, run-time switch, pseudo-localization, validation, glyph coverage check |
| `text.mojo` | UTF-8 decoding and greedy line breaking: spaces, CJK between-character breaks, closing / opening marks (kinsoku), over-long words, newlines; glyph widths come from a `GlyphMetrics` the caller supplies |

Tests: `pixi run -e wasm test-ui` builds `tests/ui_*.mojo` with the standard library only on the include path, which is
the check that this directory stands alone.

Rules (checked by `scripts/check_layout.py`):

- Mojo and Markdown only.
- Imports the standard library, `wgpu` and `ui` itself. Never engine packages, `app/` or `editor/`,
  so the directory can become a standalone library without changes.

Still to come with #17: more widgets (text field, scroll area, list), the wgpu draw path, touch gestures, IME.

Text (#116): `batch.build_batch_font` turns text runs into glyph quads; `app/hud.mojo` draws them from the atlas after the
rectangles (so text is always above panels). Font file and license: `assets/fonts/`. Checks: `test-ui` (`ui_sdf_font`, `ui_scale`,
`ui_loc`), `test-game` (HUD layout at 100 to 200 % text), `font-same` (native against wasm64), `text-shot` (headless Chrome frames),
`test-font` (importer self-test, asset hash and license). Right-to-left shaping and complex scripts are not done: follow-up.
