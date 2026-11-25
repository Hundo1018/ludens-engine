#!/usr/bin/env python3
"""Write the sample light profiles under assets/lights/: two IES LM-63-2002 files. They are made from formulas here, not
measured luminaires, so the engine's tests know what the files hold.

    pixi run -e wasm python3 scripts/assets/gen_light_profiles.py           # write them
    pixi run -e wasm python3 scripts/assets/gen_light_profiles.py --check   # fail if a file differs from what this writes

  downlight_cos8.ies  rotationally symmetric: 1000 cd * cos^8 of the angle off the axis up to 60 degrees, none past it
                      (half the peak at 23.51 degrees); 1200 lm lamp
  street_type2.ies    horizontal 90 .. 270, mirrored about the 90-270 plane (the same both ways along the road): the
                      beam leans 55 degrees toward the street (horizontal 90), little goes toward the houses (270); 8000 lm lamp
"""
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
OUT = ROOT / "assets/lights"


def ies_text(header: list[str], lumens: float, vert: list[float], horiz: list[float], cd: list[list[float]]) -> str:
    lines = ["IESNA:LM-63-2002", *header, "TILT=NONE"]
    # lamps, lumens per lamp, multiplier, vertical, horizontal, type C, units (2 m), width, length, height
    lines.append(f"1 {lumens:.1f} 1.0 {len(vert)} {len(horiz)} 1 2 0.1 0.1 0.0")
    lines.append("1.0 1.0 40.0")  # ballast factor, ballast-lamp factor, input watts
    lines.append(" ".join(f"{a:g}" for a in vert))
    lines.append(" ".join(f"{a:g}" for a in horiz))
    for row in cd:
        lines.append(" ".join(f"{v:.2f}" for v in row))
    return "\n".join(lines) + "\n"


def downlight() -> str:
    vert = [a * 2.5 for a in range(37)]
    cd = [[(1000.0 * math.cos(math.radians(a)) ** 8 if a <= 60 else 0.0) for a in vert]]
    return ies_text(["[TEST] ludens sample", "[LUMINAIRE] downlight, cos^8 to 60 degrees"], 1200.0, vert, [0.0], cd)


def street() -> str:
    vert = [float(a) for a in range(0, 91, 5)]
    horiz = [float(h) for h in range(90, 271, 15)]
    cd = []
    for h in horiz:
        # the beam's centre: 55 degrees off the axis toward horizontal 90, a Gaussian lobe 18 degrees across along the
        # street and 10 degrees across it
        row = []
        for a in vert:
            x = math.radians(a) * math.cos(math.radians(h))  # along the street
            y = math.radians(a) * math.sin(math.radians(h)) - math.radians(55.0)  # toward / away from it
            v = 6000.0 * math.exp(-0.5 * ((x / math.radians(18.0)) ** 2 + (y / math.radians(10.0)) ** 2))
            row.append(v + 300.0 * math.cos(math.radians(a)))
        cd.append(row)
    return ies_text(["[TEST] ludens sample", "[LUMINAIRE] street light, type II-like, bilateral"], 8000.0, vert, horiz, cd)


def files() -> dict[str, bytes]:
    return {
        "downlight_cos8.ies": downlight().encode(),
        "street_type2.ies": street().encode(),
    }


def main(argv: list[str]) -> int:
    check = "--check" in argv
    bad = 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in files().items():
        path = OUT / name
        if check:
            if not path.exists() or path.read_bytes() != data:
                print(f"gen_light_profiles: {path.relative_to(ROOT)} differs from what this script writes")
                bad += 1
        else:
            path.write_bytes(data)
            print(f"wrote {path.relative_to(ROOT)} ({len(data)} bytes)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
