#!/usr/bin/env python3
"""Sign Oriel's app payload, rebuild its NSIS installer, then sign the installer."""
import base64
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

sdk = Path(os.environ["ProgramFiles(x86)"]) / "Windows Kits/10/bin"
signtool = str(sorted(sdk.glob("*/x64/signtool.exe"))[-1])
makensis = shutil.which("makensis") or str(Path(os.environ["ProgramFiles(x86)"]) / "NSIS/makensis.exe")

candidate_dirs = [
    Path(".zig-cache"),
    Path("../.zig-cache"),
]
if "ZIG_LOCAL_CACHE_DIR" in os.environ:
    candidate_dirs.append(Path(os.environ["ZIG_LOCAL_CACHE_DIR"]))
if "ZIG_GLOBAL_CACHE_DIR" in os.environ:
    candidate_dirs.append(Path(os.environ["ZIG_GLOBAL_CACHE_DIR"]))

scripts = []
seen = set()
for d in candidate_dirs:
    try:
        resolved = d.resolve()
    except Exception:
        resolved = d
    if resolved.is_dir() and resolved not in seen:
        seen.add(resolved)
        scripts.extend(resolved.rglob("installer.nsi"))
if not scripts:
    scripts.extend(Path("..").rglob("installer.nsi"))
if not scripts:
    raise SystemExit("Could not find installer.nsi in any cache directory")

script = max(scripts, key=lambda p: p.stat().st_mtime)
text = script.read_text()
payload = re.search(r'^!define BINARY_SRC\s+"([^"]+)"', text, re.M)
installer = re.search(r'^!define OUT_FILE\s+"([^"]+)"', text, re.M)
if not payload or not installer:
    raise SystemExit("Could not resolve app and installer from Oriel's NSIS script")
with tempfile.TemporaryDirectory(prefix="hollershare-sign-", dir=os.environ["RUNNER_TEMP"]) as temporary:
    certificate = Path(temporary) / "codesign.pfx"
    certificate.write_bytes(base64.b64decode(os.environ["ORIEL_WINDOWS_CERT_P12_BASE64"], validate=True))
    # Trust on LocalMachine (avoids modal confirmation dialog on Windows headless runner)
    ps = "$c=[System.Security.Cryptography.X509Certificates.X509Certificate2]::new($env:HOLLERSHARE_CERT,$env:ORIEL_WINDOWS_CERT_PASSWORD); $s=[System.Security.Cryptography.X509Certificates.X509Store]::new('Root','LocalMachine'); $s.Open('ReadWrite'); $s.Add([System.Security.Cryptography.X509Certificates.X509Certificate2]::new($c.RawData)); $s.Close()"
    subprocess.run(["pwsh", "-NoProfile", "-Command", ps], env=dict(os.environ, HOLLERSHARE_CERT=str(certificate)), check=True)
    timestamp_urls = [
        "http://timestamp.digicert.com",
        "http://timestamp.sectigo.com",
    ]
    def sign(path):
        last_error = None
        for ts in timestamp_urls:
            result = subprocess.run([signtool, "sign", "/f", str(certificate), "/p", os.environ["ORIEL_WINDOWS_CERT_PASSWORD"], "/fd", "SHA256", "/tr", ts, "/td", "SHA256", str(path)])
            if result.returncode == 0:
                break
            last_error = result.returncode
        else:
            raise SystemExit(f"Code signing failed (exit {last_error})")
        subprocess.run([signtool, "verify", "/pa", str(path)], check=True)
    binary = Path(payload.group(1).replace("$$", "$"))
    sign(binary)
    Path("zig-out/bin").mkdir(parents=True, exist_ok=True)
    shutil.copy2(binary, "zig-out/bin/hollershare.exe")
    subprocess.run([makensis, "/NOCD", "/WX", str(script.resolve())], check=True)
    setup = Path(installer.group(1).replace("$$", "$"))
    sign(setup)
    Path("zig-out/package").mkdir(parents=True, exist_ok=True)
    shutil.copy2(setup, Path("zig-out/package") / setup.name)
