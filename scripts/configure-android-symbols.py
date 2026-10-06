#!/usr/bin/env python3
"""Enable matching native debug symbols in an Oriel-generated Gradle project."""
from pathlib import Path

path = Path("android/app/build.gradle.kts")
source = path.read_text()
# Match the NDK installed by the Android release workflow.
if "ndkVersion =" not in source:
    source = source.replace("android {\n", 'android {\n    ndkVersion = "28.2.13676358"\n', 1)
if 'debugSymbolLevel = "FULL"' not in source:
    marker = "        release {\n"
    if source.count(marker) != 1:
        raise SystemExit("Expected one release build type in the generated Gradle project")
    source = source.replace(marker, marker + '            ndk { debugSymbolLevel = "FULL" }\n')
source = source.replace(
    '// Release libraries come stripped from Zig, Debug ones keep their\n'
    '        // symbols: either way Gradle keeps the libraries as built.\n'
    '        jniLibs.keepDebugSymbols += "**/*.so"',
    '// Gradle extracts native symbols and strips release JNI libraries.\n'
    '        // HollerShare retains the original symbols during the Zig build.'
)
if 'jniLibs.keepDebugSymbols += "**/*.so"' in source:
    raise SystemExit("Unexpected keepDebugSymbols configuration: release libraries must be stripped by Gradle")
path.write_text(source)
print("Enabled FULL native debug symbols for Android releases")
