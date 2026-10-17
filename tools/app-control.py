#!/usr/bin/env python3
"""Give Altium's GUI-owning Wine loader a native macOS app identity.

Close Altium first. Usage: app-control.py WINE_APP RUNTIME_APP
Restore the original loader with: app-control.py WINE_APP --restore
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import tempfile


MARKER = "# altium-wine app-control loader"


def atomic_copy(source, target):
    temporary = target.with_name(target.name + ".tmp-app-control")
    shutil.copy2(source, temporary)
    os.replace(temporary, target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wine_app", type=Path)
    parser.add_argument("runtime_app", nargs="?", type=Path)
    parser.add_argument("--bundle-id", default="local.altium-wine.runtime.ad26")
    parser.add_argument("--restore", action="store_true")
    args = parser.parse_args()
    wine = args.wine_app.resolve() / "Contents/Resources/wine"
    loader = wine / "lib/wine/x86_64-unix/wine"
    original = loader.with_name("wine.before-app-control")
    if not loader.is_file() or not (loader.parent / "ntdll.so").is_file():
        parser.error("Expected a Wine macOS bundle with its loader and ntdll.so")
    managed = loader.is_file() and MARKER.encode() in loader.read_bytes()[:256]
    if args.restore:
        if not managed or not original.is_file():
            parser.error("No managed app-control loader to restore")
        atomic_copy(original, loader)
        return
    if args.runtime_app is None:
        parser.error("RUNTIME_APP is required")
    runtime = args.runtime_app.absolute()
    if runtime.suffix != ".app" or runtime.exists():
        parser.error("Choose a new .app directory")
    if not (wine / "lib/libMoltenVK.dylib").is_file():
        parser.error("Wine's libMoltenVK.dylib is missing")
    if original.exists():
        if not managed and loader.read_bytes() != original.read_bytes():
            parser.error("Refusing to overwrite an unrecognized Wine loader")
    else:
        if loader.read_bytes()[:4] not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
            parser.error("Expected Wine's original Mach-O loader")
        shutil.copy2(loader, original)
    runtime.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".altium-app-", dir=runtime.parent))
    try:
        contents = staging / "Contents"
        binary = contents / "MacOS"
        icd = contents / "Resources/vulkan/icd.d"
        binary.mkdir(parents=True)
        icd.mkdir(parents=True)
        shutil.copy2(original, binary / "wine")
        (binary / "ntdll.so").symlink_to(wine / "lib/wine/x86_64-unix/ntdll.so")
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(dict(CFBundleIdentifier=args.bundle_id,
                              CFBundleName="Altium Designer", CFBundleDisplayName="Altium Designer",
                              CFBundleExecutable="wine", CFBundlePackageType="APPL",
                              CFBundleVersion="1", NSPrincipalClass="WineApplication",
                              LSMinimumSystemVersion="10.15"), stream)
        # Bundling changes Vulkan's driver search path. Keep DXVK/MoltenVK working.
        (icd / "MoltenVK_icd.json").write_text(json.dumps({
            "file_format_version": "1.0.0", "ICD": {
                "library_path": str(wine / "lib/libMoltenVK.dylib"),
                "api_version": "1.4.0", "is_portability_driver": True}}) + "\n")
        subprocess.run(["codesign", "--force", "--sign", "-", str(staging)], check=True)
        staging.rename(runtime)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    # Match the executable argument only: WebView also mentions X2.EXE in its flags.
    script = (f"#!/bin/sh\n{MARKER}\ncase \"${{1-}}\" in\n"
              f"  *X2.EXE|*X2.exe|*x2.exe)\n"
              f"    if [ -x {shlex.quote(str(runtime / 'Contents/MacOS/wine'))} ]; then\n"
              f"      exec {shlex.quote(str(runtime / 'Contents/MacOS/wine'))} \"$@\"\n"
              "    fi ;;\nesac\n"
              f"exec {shlex.quote(str(original))} \"$@\"\n")
    temporary = loader.with_name("wine.tmp-app-control")
    temporary.write_text(script)
    temporary.chmod(0o755)
    os.replace(temporary, loader)
    subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/"
                    "LaunchServices.framework/Support/lsregister", "-f", str(runtime)], check=True)
    print(f"App control: {args.bundle_id}\nRuntime: {runtime}")


if __name__ == "__main__":
    main()
