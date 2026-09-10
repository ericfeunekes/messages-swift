#!/usr/bin/env python3
import argparse
import os
import plistlib
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--label", required=True); parser.add_argument("--output", required=True)
parser.add_argument("--stdout", required=True); parser.add_argument("--stderr", required=True)
parser.add_argument("arguments", nargs="+")
args = parser.parse_args()
output = Path(args.output); output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
temporary = output.with_suffix(output.suffix + ".tmp")
with temporary.open("wb") as handle:
    plistlib.dump({"Label": args.label, "ProgramArguments": args.arguments, "RunAtLoad": True, "KeepAlive": True, "ThrottleInterval": 30, "StandardOutPath": args.stdout, "StandardErrorPath": args.stderr}, handle, sort_keys=False)
os.chmod(temporary, 0o600); temporary.replace(output)
