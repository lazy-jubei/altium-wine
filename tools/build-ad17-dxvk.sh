#!/bin/bash
# Build the optional 32-bit Metal renderer. Does not modify a Wine prefix.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${AD17_DXVK_BUILD_ROOT:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}/build/ad17-dxvk}"
LLVM="${LLVM_MINGW:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}/tools/llvm-mingw}"
LLVM="$(cd "$LLVM" && pwd)"
export PATH="$LLVM/bin:$PATH"
for tool in cmake meson ninja glslangValidator i686-w64-mingw32-g++; do
    command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 1; }
done
mkdir -p "$BUILD_ROOT/downloads"
BUILD_ROOT="$(cd "$BUILD_ROOT" && pwd)"
fetch() {
    local name="$1" sha="$2" url="$3"
    if [ ! -f "$BUILD_ROOT/downloads/$name" ]; then
        curl -fL --retry 3 "$url" -o "$BUILD_ROOT/downloads/$name.part"
        mv "$BUILD_ROOT/downloads/$name.part" "$BUILD_ROOT/downloads/$name"
    fi
    printf '%s  %s\n' "$sha" "$BUILD_ROOT/downloads/$name" | shasum -a 256 -c -
}
fetch dxvk.tar.gz b3fc4a0415b3e4cdfb40497bec191c10f183ec2eb498950aa1f638f176cb996b \
    https://codeload.github.com/Gcenx/DXVK-macOS/tar.gz/8f1e28deed3ad30802f7e1bdff428ec14e6e7817
fetch spirv-tools.tar.gz 92df4c377603f086c3d2a1eb2bd9b8f883a73ca890fb939d78a0cecdcc01686c \
    https://codeload.github.com/KhronosGroup/SPIRV-Tools/tar.gz/refs/tags/v2026.4
fetch spirv-headers.tar.gz a9bb9c48713245eacf97cc539b6f1d45405a92d8813f8b82e635f0a085ee9898 \
    https://codeload.github.com/KhronosGroup/SPIRV-Headers/tar.gz/496543121ce6419f23d6fa5d7194ba66c36212d2
for tree in dxvk spirv-tools; do
    if [ ! -d "$BUILD_ROOT/$tree" ]; then
        mkdir "$BUILD_ROOT/$tree"
        tar -xzf "$BUILD_ROOT/downloads/$tree.tar.gz" --strip-components 1 -C "$BUILD_ROOT/$tree"
    fi
done
if [ ! -d "$BUILD_ROOT/spirv-tools/external/spirv-headers/include" ]; then
    mkdir -p "$BUILD_ROOT/spirv-tools/external/spirv-headers"
    tar -xzf "$BUILD_ROOT/downloads/spirv-headers.tar.gz" --strip-components 1 \
        -C "$BUILD_ROOT/spirv-tools/external/spirv-headers"
fi
patch_hash="$(shasum -a 256 "$KIT_DIR/patches/dxvk-ad17-metal.patch" | cut -d ' ' -f 1)"
patch_stamp="$BUILD_ROOT/dxvk/.altium-metal-patched"
if [ -f "$patch_stamp" ]; then
    [ "$(cat "$patch_stamp")" = "$patch_hash" ] || {
        echo "DXVK patch changed since this build tree was prepared. Use a fresh AD17_DXVK_BUILD_ROOT." >&2
        exit 1
    }
else
    (cd "$BUILD_ROOT/dxvk" && patch -p1 < "$KIT_DIR/patches/dxvk-ad17-metal.patch")
    printf '%s\n' "$patch_hash" > "$patch_stamp"
fi
cat > "$BUILD_ROOT/win32.cmake" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86)
set(CMAKE_C_COMPILER "$LLVM/bin/i686-w64-mingw32-gcc")
set(CMAKE_CXX_COMPILER "$LLVM/bin/i686-w64-mingw32-g++")
set(CMAKE_AR "$LLVM/bin/llvm-ar")
set(CMAKE_RANLIB "$LLVM/bin/llvm-ranlib")
set(CMAKE_CXX_FLAGS_INIT "-DNOMINMAX -D_WIN32_WINNT=0xa00")
EOF
cmake -S "$BUILD_ROOT/spirv-tools" -B "$BUILD_ROOT/spirv-build" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$BUILD_ROOT/win32.cmake" -DCMAKE_BUILD_TYPE=Release \
    -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_TOOLS_BUILD_STATIC=ON
cmake --build "$BUILD_ROOT/spirv-build" --target SPIRV-Tools-opt --parallel "${JOBS:-6}"
args=("$BUILD_ROOT/dxvk-build" "$BUILD_ROOT/dxvk" --cross-file "$BUILD_ROOT/dxvk/build-win32.txt"
    --buildtype release -Dstrip=true -Denable_d3d9=true -Denable_d3d10=false
    -Denable_d3d11=false -Denable_dxgi=false
    "-Dspirv_tools_source=$BUILD_ROOT/spirv-tools" "-Dspirv_tools_build=$BUILD_ROOT/spirv-build")
if [ -f "$BUILD_ROOT/dxvk-build/build.ninja" ]; then
    meson setup --reconfigure "${args[@]}"
else
    meson setup "${args[@]}"
fi
ninja -C "$BUILD_ROOT/dxvk-build" -j "${JOBS:-6}"
mkdir -p "$BUILD_ROOT/output/licenses"
cp "$BUILD_ROOT/dxvk-build/src/d3d9/d3d9.dll" "$BUILD_ROOT/output/"
cp "$BUILD_ROOT/dxvk/LICENSE" "$BUILD_ROOT/output/licenses/DXVK.txt"
cp "$BUILD_ROOT/spirv-tools/LICENSE" "$BUILD_ROOT/output/licenses/SPIRV-Tools.txt"
cp "$BUILD_ROOT/spirv-tools/external/spirv-headers/LICENSE" "$BUILD_ROOT/output/licenses/SPIRV-Headers.txt"
(cd "$BUILD_ROOT/output" && shasum -a 256 d3d9.dll > SHA256SUMS)
printf 'Built renderer: %s/output/d3d9.dll\n' "$BUILD_ROOT"
