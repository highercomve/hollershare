#!/usr/bin/env python3
"""Use Oriel to combine signed entries into the release's single update feed."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path("dist")
paths = sorted(root.glob("update-*.json"))
manifests = [json.loads(path.read_text()) for path in paths]
expected = {"x86_64-linux", "x86_64-linux-appimage", "aarch64-macos", "x86_64-windows", "aarch64-android", "x86_64-android"}
if {item["target"] for item in manifests} != expected: raise SystemExit("Missing update platforms")
if len({(item["app_id"], item["version"]) for item in manifests}) != 1: raise SystemExit("Inconsistent update identity or version")
subprocess.run(["oriel", "build", "combine-manifests", "--", *map(str, paths), "--out", str(root / "latest.json")], check=True)
# These are build intermediates. Clients on every platform use latest.json.
for path in paths:
    path.unlink()
with (root / "SHA256SUMS").open("w") as sums:
    for path in sorted(root.iterdir()):
        if path.is_file() and not path.name.startswith("SHA256SUMS"):
            sums.write(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n")
print("Combined six signed update targets")
