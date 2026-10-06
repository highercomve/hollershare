#!/usr/bin/env python3
"""Install the released CLI matching the tagged app framework."""
import os
from pathlib import Path
import subprocess

framework = Path("../oriel").resolve()
if not (framework / "build.zig").is_file():
    raise SystemExit("Oriel development checkout is required at ../oriel")
revision = subprocess.check_output(["git", "-C", str(framework), "rev-parse", "HEAD"], text=True).strip()
expected = os.environ.get("ORIEL_REF")
if expected:
    requested = subprocess.check_output(["git", "-C", str(framework), "rev-parse", expected + "^{commit}"], text=True).strip()
    if revision != requested:
        raise SystemExit("Oriel checkout does not match the requested CI revision")
tag = expected or "v0.9.3"
folder = Path(os.environ.get("RUNNER_TEMP", ".oriel-cli")).resolve() / "oriel-release-bin"
env = dict(os.environ, ORIEL_VERSION=tag, ORIEL_INSTALL_DIR=str(folder))
installer = "install.ps1" if os.name == "nt" else "install.sh"
command = ["pwsh", "-NoProfile", "-File"] if os.name == "nt" else ["sh"]
# The tagged official installers download release binaries and verify SHA256SUMS.
subprocess.run(command + [str(framework / installer)], env=env, check=True)
if os.environ.get("GITHUB_PATH"):
    with open(os.environ["GITHUB_PATH"], "a") as file:
        file.write(str(folder) + "\n")
print("Installed released Oriel CLI " + tag + " for framework " + revision)
