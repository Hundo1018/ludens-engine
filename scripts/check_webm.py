#!/usr/bin/env python3
"""B5 recording check: the WebM decodes end to end with ffmpeg and covers about the requested seconds.

usage: check_webm.py <file.webm> <seconds>"""
import re
import subprocess
import sys


def main() -> int:
    path, want = sys.argv[1], float(sys.argv[2])
    probe = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,codec_name,width,height",
                            "-of", "csv=p=0", path], capture_output=True, text=True)
    decode = subprocess.run(["ffmpeg", "-v", "error", "-stats", "-i", path, "-f", "null", "-"], capture_output=True, text=True)
    times = re.findall(r"time=(\d+):(\d+):([\d.]+)", decode.stderr)
    seconds = 0.0
    if times:
        h, m, s = times[-1]
        seconds = int(h) * 3600 + int(m) * 60 + float(s)
    errors = [l for l in decode.stderr.replace("\r", "\n").splitlines() if l and "time=" not in l]
    print("streams:", " ".join(probe.stdout.split()))
    print(f"decoded {seconds:.2f} s, decode errors: {len(errors)}")
    ok = probe.returncode == 0 and decode.returncode == 0 and not errors and want - 0.75 <= seconds <= want + 1.5
    print("check_webm:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
