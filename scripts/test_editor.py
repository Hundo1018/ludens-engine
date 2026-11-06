#!/usr/bin/env python3
"""Build and run the editor command-layer test natively (no GPU).

    pixi run -e wasm test-editor"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_native  # noqa: E402

if __name__ == "__main__":
    sys.exit(test_native.main(["editor_command", "editor_ext"]))
