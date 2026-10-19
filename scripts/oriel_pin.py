"""Read the released Oriel tag and immutable revision from build.zig.zon."""
from pathlib import Path
import re
from urllib.parse import parse_qs, urlsplit


def read_pin(path=Path("build.zig.zon")):
    dependency = re.search(r'\.oriel\s*=\s*\.\{([^}]+)\}', path.read_text())
    match = re.search(r'\.url\s*=\s*"([^"\n]+)"', dependency.group(1)) if dependency else None
    if not match:
        raise ValueError("Missing Oriel dependency URL in build.zig.zon")
    url = urlsplit(match.group(1).removeprefix("git+"))
    if (url.scheme, url.netloc, url.path) != ("https", "github.com", "/highercomve/Oriel"):
        raise ValueError("Expected the official Oriel GitHub dependency")
    refs = parse_qs(url.query).get("ref", [])
    if len(refs) != 1 or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", refs[0]):
        raise ValueError("Oriel must pin a release tag using ?ref=vX.Y.Z")
    if not re.fullmatch(r"[0-9a-f]{40}", url.fragment):
        raise ValueError("Oriel must pin a full Git commit after #")
    return refs[0], url.fragment


if __name__ == "__main__":
    tag, revision = read_pin()
    print(f"tag={tag}\nrevision={revision}")
