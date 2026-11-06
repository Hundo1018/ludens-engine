# ui/

Shared UI toolkit for the game and the editor (ludens-shell #17).

| Module | What |
|---|---|
| `geom.mojo` | `Rect`, `Insets` |
| `layout.mojo` | Flex-style rows and columns: fixed size, grow, shrink, padding, gap, align, justify; measure + arrange |
| `focus.mojo` | Directional focus navigation (arrow keys, d-pad, swipe) with Android's weighted distance, optional wrap |
| `text.mojo` | UTF-8 decoding and greedy line breaking: spaces, CJK between-character breaks, closing / opening marks (kinsoku), over-long words, newlines; glyph widths come from a `GlyphMetrics` the caller supplies |

Tests: `pixi run -e wasm test-ui` builds `tests/ui_*.mojo` with the standard library only on the include path, which is
the check that this directory stands alone.

Rules (checked by `scripts/check_layout.py`):

- Mojo and Markdown only.
- Imports the standard library, `wgpu` and `ui` itself. Never engine packages, `app/` or `editor/`,
  so the directory can become a standalone library without changes.

Still to come with #17: font loading and the glyph atlas, widgets, styling, the wgpu draw path, touch gestures, IME.
