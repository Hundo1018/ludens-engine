# assets/fonts/

Font assets in the engine's `.lfont` format (SDF atlas, read by `ui/sdf_font.mojo`; format in
`scripts/assets/convert_font.py`).

| File | Source | License |
|---|---|---|
| `NotoSansTC-Regular-24.lfont` | Noto Sans CJK TC, Regular, subset OTF (`NotoSansTC-Regular.otf`) | SIL Open Font License 1.1, `OFL.txt` |

- Copyright (from the font's name table): "Copyright 2014-2021 Adobe (http://www.adobe.com/). Noto is a trademark of Google Inc."
- The OFL permits redistribution and embedding, alone or bundled, if the license text travels with it and the font is not
  sold on its own. `OFL.txt` is that text. The `.lfont` is a derived rasterisation of the font (distance values, no
  outlines); it is distributed under the same license, with `OFL.txt`.
- Source file: `https://github.com/notofonts/noto-cjk/tree/main/Sans/SubsetOTF/TC/NotoSansTC-Regular.otf`, fetched through
  `https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/SubsetOTF/TC/NotoSansTC-Regular.otf` on 2026-11-23,
  5 683 368 bytes, sha256 `5bab0cb3c1cf89dde07c4a95a4054b195afbcfe784d69d75c340780712237537`.
  The OTF is not in the repository (5.7 MB); download it from there to rebuild.

Rebuild (same bytes with the pinned Pillow; the sha256 below is checked by `pixi run -e wasm test-font`):

```
pixi run -e wasm python3 scripts/assets/convert_font.py NotoSansTC-Regular.otf assets/fonts/NotoSansTC-Regular-24.lfont
```

`NotoSansTC-Regular-24.lfont`: em 24 px, spread 4 px, 5984 glyphs (Latin, Latin-1, 408 Big5 symbols, 5401 Big5 level 1
ideographs, the box glyph), atlas 2048 x 3104, 6 476 720 bytes (1 836 745 gzip),
sha256 `85498b0b8644fb71b501ea0931863f20761bab3654541840c64d3ec622f55673`.
Four code points of the requested set have no outline in the font and are not in the file: U+02CD, U+203E, U+223C, U+2252.
