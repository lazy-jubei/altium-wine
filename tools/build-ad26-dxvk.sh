#!/bin/bash
# Build the optional AD26 D3D11 renderer without modifying an installation.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${AD26_DXVK_BUILD_ROOT:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}/build/ad26-dxvk}"
LLVM="${LLVM_MINGW:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}/tools/llvm-mingw}"
LLVM="$(cd "$LLVM" && pwd)"
export PATH="$LLVM/bin:$PATH"
for tool in meson ninja glslangValidator x86_64-w64-mingw32-g++; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$BUILD_ROOT/downloads"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
archive="$BUILD_ROOT/downloads/dxvk.tar.gz"
if [ ! -f "$archive" ]; then
    curl -fL --retry 3 https://codeload.github.com/Gcenx/DXVK-macOS/tar.gz/8f1e28deed3ad30802f7e1bdff428ec14e6e7817 -o "$archive.part"
    mv "$archive.part" "$archive"
fi
printf '%s  %s\n' b3fc4a0415b3e4cdfb40497bec191c10f183ec2eb498950aa1f638f176cb996b "$archive" | shasum -a 256 -c -
if [ ! -d "$BUILD_ROOT/dxvk" ]; then
    mkdir "$BUILD_ROOT/dxvk"
    tar -xzf "$archive" --strip-components 1 -C "$BUILD_ROOT/dxvk"
fi
patch_sha="$(shasum -a 256 "$KIT_DIR/patches/dxvk-ad26-gdi.patch" | awk '{print $1}')"
stamp="$BUILD_ROOT/dxvk/.altium-gdi-patched"
if [ -e "$stamp" ]; then
    [ "$(cat "$stamp")" = "$patch_sha" ] || { echo 'Source patch changed; use a fresh AD26_DXVK_BUILD_ROOT.' >&2; exit 1; }
else
    patch -d "$BUILD_ROOT/dxvk" -p1 -N -t < "$KIT_DIR/patches/dxvk-ad26-gdi.patch"
    printf '%s\n' "$patch_sha" > "$stamp"
fi
args=("$BUILD_ROOT/dxvk-build" "$BUILD_ROOT/dxvk" --cross-file "$BUILD_ROOT/dxvk/build-win64.txt"
    --buildtype release -Dstrip=true -Denable_d3d9=false -Denable_d3d10=true
    -Denable_d3d11=true -Denable_dxgi=false)
if [ -f "$BUILD_ROOT/dxvk-build/build.ninja" ]; then meson setup --reconfigure "${args[@]}";
else meson setup "${args[@]}"; fi
ninja -C "$BUILD_ROOT/dxvk-build" -j "${JOBS:-6}"
mkdir -p "$BUILD_ROOT/output/licenses"
cp "$BUILD_ROOT/dxvk-build/src/d3d11/d3d11.dll" "$BUILD_ROOT/dxvk-build/src/d3d10/d3d10core.dll" "$BUILD_ROOT/output/"
cp "$BUILD_ROOT/dxvk/LICENSE" "$BUILD_ROOT/output/licenses/DXVK.txt"
(cd "$BUILD_ROOT/output" && shasum -a 256 d3d11.dll d3d10core.dll > SHA256SUMS)
printf 'Built renderer: %s/output\n' "$BUILD_ROOT"
