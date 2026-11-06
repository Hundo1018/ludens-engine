# ui/

Shared UI toolkit for the game and the editor (ludens-shell #17).

| Module | What |
|---|---|
| `geom.mojo` | `Rect`, `Insets` |
| `layout.mojo` | Flex-style rows and columns: fixed size, grow, shrink, padding, gap, align, justify; measure + arrange |
| `focus.mojo` | Directional focus navigation (arrow keys, d-pad, swipe) with Android's weighted distance, optional wrap |
| `draw.mojo` | The draw list: fill, stroke, text run, clip push / pop. No GPU object and no font; `DrawList.hash()` covers every field of every command |
| `immediate.mojo` | Immediate-mode widgets (`button`, `checkbox`, `slider`, `label`) on a `Ui`: pointer clicks (press and release on the same widget), Enter / Space, arrow-key focus movement with Android's rule, sliders keep Left / Right, disabled widgets, a `Theme` |
| `text.mojo` | UTF-8 decoding and greedy line breaking: spaces, CJK between-character breaks, closing / opening marks (kinsoku), over-long words, newlines; glyph widths come from a `GlyphMetrics` the caller supplies |

Tests: `pixi run -e wasm test-ui` builds `tests/ui_*.mojo` with the standard library only on the include path, which is
the check that this directory stands alone.

Rules (checked by `scripts/check_layout.py`):

- Mojo and Markdown only.
- Imports the standard library, `wgpu` and `ui` itself. Never engine packages, `app/` or `editor/`,
  so the directory can become a standalone library without changes.

Still to come with #17: font loading and the glyph atlas, more widgets (text field, scroll area, list), the wgpu draw path, touch gestures, IME.
