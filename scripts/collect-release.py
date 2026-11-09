#!/usr/bin/env python3
import hashlib
from pathlib import Path
import re
import shutil
import sys
import tarfile

platform = sys.argv[1]
output = Path("dist")
output.mkdir(exist_ok=True)
roots = [Path("zig-out/package")] if platform != "android" else [Path("android/app/build/outputs/apk/release"), Path("android/app/build/outputs/bundle/release")]
# `zig build package-executable` installs the checked, stripped bare
# executable as zig-out/package/hollershare-<version>-<arch>-<os>[.exe]. It is
# the updater payload, published once below under its own name, never as a
# package and never from zig-out/bin.
update_payload = None
if platform in {"linux-x86_64", "windows-x86_64"}:
    system, arch = platform.split("-", 1)
    suffix = ".exe" if system == "windows" else ""
    name = re.compile(r"hollershare-[0-9]+\.[0-9]+\.[0-9]+\S*-" + re.escape(f"{arch}-{system}{suffix}"))
    payloads = sorted(path for path in Path("zig-out/package").iterdir() if path.is_file() and name.fullmatch(path.name))
    if len(payloads) != 1:
        raise SystemExit("Expected one updater executable from `zig build package-executable` in zig-out/package, found: " + (", ".join(map(str, payloads)) or "none"))
    update_payload = payloads[0]
count = 0
for root in roots:
    for path in root.rglob("*"):
        if path == update_payload:
            continue
        if path.is_file() and path.suffix.lower() in {".deb", ".rpm", ".appimage", ".dmg", ".exe", ".apk", ".aab"}:
            shutil.copy2(path, output / f"hollershare-{platform}-{path.name}")
            count += 1
if platform == "android":
    symbols = Path("android/app/build/outputs/native-debug-symbols/release/native-debug-symbols.zip")
    if not symbols.is_file():
        raise SystemExit("Android release is missing native-debug-symbols.zip")
    shutil.copy2(symbols, output / "hollershare-android-native-debug-symbols.zip")
# Updater payloads preserve the executable or the complete signed app bundle.
if update_payload:
    shutil.copy2(update_payload, output / (f"hollershare-{platform}-update" + suffix))
elif platform == "macos-arm64":
    with tarfile.open(output / "hollershare-macos-arm64-update.app.tar.gz", "w:gz") as archive:
        archive.add("zig-out/package/HollerShare.app", arcname="HollerShare.app")
if not count:
    raise SystemExit("No release packages found")
with (output / f"SHA256SUMS-{platform}").open("w") as checksums:
    for path in sorted(output.iterdir()):
        if path.name.startswith("SHA256SUMS") or not path.is_file(): continue
        checksums.write(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n")
print(f"Collected {count} {platform} packages")
