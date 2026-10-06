#!/usr/bin/env python3
"""Apply HollerShare's Android SDK settings after Oriel generates Gradle."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--version", required=True)
parser.add_argument("--version-code", type=int)
args = parser.parse_args()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", args.version):
    parser.error("version must be major.minor.patch")
major, minor, patch = map(int, args.version.split("."))
if minor >= 100 or patch >= 100:
    parser.error("minor and patch must be below 100 for Android version codes")
code = args.version_code if args.version_code is not None else major * 10000 + minor * 100 + patch
if not 1 <= code <= 2100000000:
    parser.error("version code must be between 1 and 2100000000")

def replace_once(text, pattern, value):
    result, count = re.subn(pattern, lambda match: value, text)
    if count != 1:
        raise SystemExit(f"Expected exactly one Gradle setting matching {pattern!r}, found {count}")
    return result

app = Path("android/app/build.gradle.kts")
text = app.read_text()
for setting, value in [("compileSdk", "36"), ("targetSdk", "36"), ("versionCode", str(code)), ("versionName", f'"{args.version}"')]:
    text = replace_once(text, rf"(?m)^ *{setting} = [^\n]+", f"        {setting} = {value}" if setting != "compileSdk" else f"    {setting} = {value}")
app.write_text(text)
root = Path("android/build.gradle.kts")
text = replace_once(root.read_text(), r'id\("com.android.application"\) version "[^"]+"', 'id("com.android.application") version "8.9.3"')
root.write_text(text)
print(f"Android API 36, AGP 8.9.3, version {args.version} ({code})")
