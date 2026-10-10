#!/usr/bin/env python3
"""Writes buildServer.json into a fixture for one candidate (what the candidate's `init` writes).

usage: write_build_server.py FIXTURE_DIR CANDIDATE WORKSPACE [PLATFORM]
  CANDIDATE: xcode-bsp | xcode-build-server-log   (the second needs a build log, see run_matrix.py)
"""
import json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BSP = HERE / "vendor/sourcekit-xcode-bsp/.build/release/sourcekit-xcode-bsp"
XBS = HERE / "vendor/xcode-build-server/xcode-build-server"

fixture, candidate, workspace = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
platform = sys.argv[4] if len(sys.argv) > 4 else None
if candidate == "xcode-bsp":
    config = {"argv": [str(BSP)], "bspVersion": "2.1.0", "languages": ["swift"], "name": "sourcekit-xcode-bsp",
              "version": "0.1.0", "workspace": workspace}
    if platform:
        config["platform"] = platform
else:
    raise SystemExit("unknown candidate " + candidate)
(fixture / "buildServer.json").write_text(json.dumps(config, indent=2) + "\n")
print(fixture / "buildServer.json")
