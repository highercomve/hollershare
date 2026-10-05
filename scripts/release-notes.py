#!/usr/bin/env python3
"""Extract a release's changelog section for tags and GitHub releases."""
from pathlib import Path
import re
import sys

version = sys.argv[1].removeprefix("v")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    raise SystemExit("Expected a semantic release version")
text = Path("CHANGELOG.md").read_text()
match = re.search(r"^## \[" + re.escape(version) + r"\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.M | re.S)
if not match or not match.group(1).strip():
    raise SystemExit("Missing or empty changelog section for " + version)
print("# GhostShare " + version + "\n\n" + match.group(1).strip())
