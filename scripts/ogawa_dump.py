#!/usr/bin/env python3
"""Print the Ogawa tree of an Alembic `.abc` file (ROADMAP 17.63).

Ogawa layout: 16-byte header ("Ogawa", frozen flag 0xff, version u16,
root group offset u64); a group is a u64 child count then one u64 per
child, bit 63 set for data; data is a u64 size then the bytes; offset 0
is the empty group / empty data. Used to compare the files
`physics.abc_file` writes with ones Blender writes.

Usage: ogawa_dump.py FILE [--bytes N]   (N = data bytes shown, default 48)
"""

import struct
import sys

DATA_BIT = 1 << 63


def dump(buf: bytes, show: int) -> None:
    magic, frozen, version, root = buf[:5], buf[5], struct.unpack_from("<H", buf, 6)[0], struct.unpack_from("<Q", buf, 8)[0]
    print(f"magic {magic!r} frozen {frozen:#x} version {version} root @{root}")

    def group(off: int, path: str, depth: int) -> None:
        if off == 0:
            print(f"{'  ' * depth}{path}: empty group")
            return
        n = struct.unpack_from("<Q", buf, off)[0]
        kids = struct.unpack_from(f"<{n}Q", buf, off + 8)
        print(f"{'  ' * depth}{path}: group @{off}, {n} children")
        for i, k in enumerate(kids):
            p = f"{path}/{i}"
            if k & DATA_BIT:
                o = k & ~DATA_BIT
                if o == 0:
                    print(f"{'  ' * (depth + 1)}{p}: empty data")
                    continue
                size = struct.unpack_from("<Q", buf, o)[0]
                body = buf[o + 8 : o + 8 + min(size, show)]
                print(f"{'  ' * (depth + 1)}{p}: data @{o}, {size} bytes: {body.hex()}{'...' if size > show else ''}")
            else:
                group(k, p, depth + 1)

    group(root, "", 0)


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    show = 48
    if "--bytes" in sys.argv:
        show = int(sys.argv[sys.argv.index("--bytes") + 1])
    with open(sys.argv[1], "rb") as f:
        dump(f.read(), show)
    return 0


if __name__ == "__main__":
    sys.exit(main())
