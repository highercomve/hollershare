#!/usr/bin/env python3
"""Use Oriel's signer on release payloads; the seed never enters the repository."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

platform = sys.argv[1]
version = os.environ["GHOSTFILE_VERSION"].removeprefix("v")
tag = os.environ.get("RELEASE_TAG", "v" + version)
root = Path("dist")
payloads = {
    "linux-x86_64": [("x86_64-linux", "raw", root / "ghostshare-linux-x86_64-update")],
    "windows-x86_64": [("x86_64-windows", "raw", root / "ghostshare-windows-x86_64-update.exe")],
    "macos-arm64": [("aarch64-macos", "app.tar.gz", root / "ghostshare-macos-arm64-update.app.tar.gz")],
    "android": [(arch + "-android", "raw", root / "ghostshare-android-app-release.apk") for arch in ["aarch64", "x86_64"]],
}[platform]
if platform == "linux-x86_64":
    images = list(root.glob("*.AppImage"))
    if len(images) != 1: raise SystemExit("Expected exactly one AppImage")
    payloads.append(("x86_64-linux-appimage", "appimage", images[0]))
seed = os.environ["ORIEL_UPDATE_KEY"].strip()
if not seed: raise SystemExit("Missing updater signing seed")
with tempfile.TemporaryDirectory(prefix="ghostshare-update-") as temporary:
    key = Path(temporary) / "update.key"
    key.write_text(seed + "\n")
    key.chmod(0o600)
    for target, format_name, artifact in payloads:
        if not artifact.is_file(): raise SystemExit("Missing update payload: " + str(artifact))
        url = f"https://github.com/highercomve/ghostshare/releases/download/{tag}/{artifact.name}"
        subprocess.run(["oriel", "build", "sign-update", "--", str(artifact), "--app-id", "dev.ghostshare.App", "--version", version, "--url", url, "--key", str(key), "--target", target, "--format", format_name, "--out", str(root / ("update-" + target + ".json"))], check=True)
