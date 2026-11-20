#!/bin/bash
# Build the DXMT option from pinned sources and upstream CI modules.
# Usage: build-dxmt-modules.sh CI_ZIP_OR_RELEASE_DXMT_DIR SOURCES_DIR WINE_BUILD_DIR DXMT_OUTPUT_DIR
set -euo pipefail

[ "$#" -eq 4 ] || { sed -n '3p' "$0" >&2; exit 2; }
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary_input="$1"
sources="$2"
wine_build="$(cd "$3" && pwd)"
output="$4"
revision=0df86108348bab2aaa5c4610a5eb63a9de9047ac
headers_revision=9df86f2341616ef1888ae59919feaa6d4fad693d
dxmt_source="$sources/dxmt-source-$revision.tar.gz"
directx_source="$sources/mingw-directx-headers-$headers_revision.tar.gz"

verify() {
    local actual
    actual="$(shasum -a 256 < "$1")"
    [ "${actual%% *}" = "$2" ] || { printf 'Checksum mismatch for %s\n' "$1" >&2; exit 1; }
}

verify "$dxmt_source" d11971a0936bed26e0458ee153266d7bd263a44319d5064b94fab5314e714f42
verify "$directx_source" 9c1b8bbfd2d6c758fac4d93c2808a46bc1eee429fe656b4f21b29e02615aa8aa
[ -x "$wine_build/tools/winebuild/winebuild" ] || { echo "Build Wine's winebuild and import libraries first." >&2; exit 1; }

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/source" "$scratch/compiler/include" "$scratch/official"
if [ -d "$binary_input" ]; then
    # A published module archive keeps the four upstream binaries and the
    # same embedded command shaders even after the upstream CI artifact expires.
    windows_modules="$binary_input"
    native_modules="$binary_input"
    verify "$windows_modules/d3d10core.dll" 67d2cbb9067d6ddc4d1895e289c27e3568d22213681951c93f2c5e85350d3ea4
    verify "$windows_modules/dxgi.dll" c0d5ef8e851c8ca2940545012a268929cdbaae1975ec7400628e7a1414fd7035
    verify "$windows_modules/winemetal.dll" 2282ce9ecbf9a5d149b5931a5dd06e68bcda514f713f51b0a5e004f772adf5d6
    verify "$native_modules/winemetal.so" c2366a31efaa4aa2ab03b3f6cc62d86ab6658a4334c8aca5a465b48264cffa05
else
    verify "$binary_input" d229482aca1d6564102092c88ef322e66850897f417dd8ac745f0d59751a52ca
    unzip -p "$binary_input" "dxmt-$revision.tar.gz" | tar -xzf - -C "$scratch/official"
    windows_modules="$scratch/official/$revision/x86_64-windows"
    native_modules="$scratch/official/$revision/x86_64-unix"
fi
source_dir="$scratch/source"
tar -xzf "$dxmt_source" --strip-components 1 -C "$source_dir"
tar -xzf "$directx_source" --strip-components 1 -C "$source_dir/include/native/directx"
patch -d "$source_dir" -p1 < "$kit/patches/dxmt-gdi-surfaces.patch"

# Reuse the command shaders from the same upstream build as winemetal.so. This
# permits building just the replacement Windows DLL with Command Line Tools.
python3 - "$windows_modules/d3d11.dll" "$source_dir/src/dxmt" <<'PY'
from hashlib import sha256
from pathlib import Path
from struct import unpack_from
import sys

binary = Path(sys.argv[1]).read_bytes()
offset = binary.index(b"MTLB\x01\x80")
size = unpack_from("<Q", binary, offset + 16)[0]
shader_library = binary[offset:offset+size]
if sha256(shader_library).hexdigest() != "0cb052fa20bae7ccd659b59a6c60718a4a22816980e89c299d1a5665d75a1813":
    raise SystemExit("Unexpected DXMT command shader library")
root = Path(sys.argv[2])
(root / "dxmt_command.metallib").write_bytes(shader_library)
meson = root / "meson.build"
contents = meson.read_text()
start = contents.index("dxmt_shaders = [")
end = contents.index("dxmt_lib = ", start)
meson.write_text(contents[:start] +
                 "dxmt_shaders_header = hexdump_generator.process('dxmt_command.metallib')\n\n" +
                 contents[end:])
PY

meson setup "$scratch/build" "$source_dir" --cross-file "$source_dir/build-win64.txt" \
    --buildtype release -Dwine_build_path="$wine_build" -Dnative_llvm_path="$scratch/compiler"
ninja -C "$scratch/build" -j "$(sysctl -n hw.ncpu)" src/d3d11/d3d11.dll
dll="$scratch/build/src/d3d11/d3d11.dll"
"$wine_build/tools/winebuild/winebuild" --builtin "$dll"
/usr/bin/clang -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib -O2 \
    "$kit/tools/dxmt-metal-init.m" -framework Foundation -framework Metal -o "$scratch/metal-init.dylib"
codesign -s - -f "$scratch/metal-init.dylib"

mkdir -p "$output"
install -m 644 "$dll" "$windows_modules/"{d3d10core.dll,dxgi.dll,winemetal.dll} "$output/"
install -m 755 "$native_modules/winemetal.so" "$scratch/metal-init.dylib" "$output/"
install -m 644 "$source_dir/"{LICENSE,COPYING.LIB,LICENSE.OLD} "$output/"
