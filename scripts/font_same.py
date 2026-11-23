#!/usr/bin/env python3
"""SDF font (#116) native against wasm64: the glyph table, the rasterised text at 16 / 24 / 48 px, the glyph quads and the
missing-glyph count from app/font_parity.mojo, on the committed atlas. Equality, not tolerance.

    pixi run -e wasm font-same"""
import json
import subprocess
import sys
from pathlib import Path

import ludens_wasm_rt
from ludens_wasm_rt import parity

ROOT = Path(__file__).resolve().parent.parent
FONT = ROOT / "assets/fonts/NotoSansTC-Regular-24.lfont"
NAMES = ["glyph table", "text 16 px", "text 24 px", "text 48 px", "glyph quads", "missing glyphs"]


def build(*args: str) -> None:
    proc = subprocess.run([sys.executable, "-m", "ludens_wasm_rt.build_wasm", "-I", ".", *args],
                          cwd=ROOT, capture_output=True, text=True, check=False)
    if proc.returncode:
        sys.exit(proc.stdout + proc.stderr)


def wasm_values() -> list[int]:
    js = f"""import({json.dumps(str(ludens_wasm_rt.HOST_MJS))}).then(async m => {{
      const fs = require('fs');
      const rt = await m.instantiate(fs.readFileSync({json.dumps(str(ROOT / 'build/font_parity.wasm'))}));
      const file = fs.readFileSync({json.dumps(str(FONT))});
      const fp = rt.alloc(file.length);
      rt.put(fp, file);
      const out = rt.alloc(8 * {len(NAMES)});
      const rc = rt.call('font_parity_run', fp, BigInt(file.length), out);
      if (rc !== 0) throw new Error('font_parity_run returned ' + rc);
      console.log(Array.from(new BigUint64Array(rt.mem(), Number(out), {len(NAMES)}), x => x.toString()).join(' '));
    }}).catch(e => {{ console.error(String(e)); process.exit(1); }})"""
    r = subprocess.run(["node", "-e", js], capture_output=True, text=True, check=False)
    if r.returncode:
        sys.exit("font_same: " + (r.stdout + r.stderr)[-1500:])
    return [int(v) for v in r.stdout.split()]


def main() -> int:
    sys.path.insert(0, str(ROOT / "scripts"))
    import native_libs
    native_libs.build_all()
    build("app/font_parity.mojo", "--target", "native", "-o", "build/font_parity")
    build("app/font_parity.mojo", "--target", "wasm64", "-o", "build/font_parity.wasm", "--export", "font_parity_*")
    out = subprocess.run([str(ROOT / "build/font_parity"), str(FONT)], capture_output=True, text=True, check=True).stdout
    nat = [int(v) for v in out.split()[1:]]
    ok = parity.compare(NAMES, nat, wasm_values(), "font parity")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
