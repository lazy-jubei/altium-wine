#!/bin/bash
# Build 64-bit DXVK with the kit's Altium GDI redraw fix.
set -euo pipefail

kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(realpath -m -- "${ALTIUM_WINE_ROOT:-$HOME/AltiumWineLinux}")/build/dxvk-linux"
src="$root/source"
out="$root/output"
base=b1a1c99ab52b687cf950d62c88bc2fa316b41663
patch="$kit/patches/dxvk-ad26-gdi.patch"
gdi=src/d3d11/d3d11_gdi.cpp

for tool in git meson ninja x86_64-w64-mingw32-g++; do
    command -v "$tool" >/dev/null || { printf 'Missing build tool %s\n' "$tool" >&2; exit 1; }
done
if ! command -v glslang >/dev/null && ! command -v glslangValidator >/dev/null; then
    printf 'Missing build tool glslangValidator\n' >&2
    exit 1
fi
mkdir -p "$root"
exec 9>"$root/.build.lock"
flock 9
if [[ ! -d "$src/.git" ]]; then
    git clone --depth 1 --branch v3.1.1 https://github.com/doitsujin/dxvk.git "$src"
fi
[[ $(git -C "$src" rev-parse HEAD) = "$base" ]] || { printf 'Unexpected DXVK checkout in %s\n' "$src" >&2; exit 1; }
git -C "$src" submodule update --init --recursive --depth 1 --jobs 4
# Reuse the redraw fix. The config.cpp include change is specific to DXVK-macOS.
if ! git -C "$src" apply --reverse --check --include="$gdi" "$patch" 2>/dev/null; then
    git -C "$src" apply --include="$gdi" "$patch"
fi
if [[ ! -f "$root/build/build.ninja" ]]; then
    meson setup "$root/build" "$src" --cross-file "$src/build-win64.txt" --buildtype release -Db_ndebug=if-release
fi
meson compile -C "$root/build" -j "${DXVK_JOBS:-$(nproc)}" d3d11 dxgi d3d10core
stage="$(mktemp -d "$root/.output.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
install -m 644 "$root/build/src/d3d11/d3d11.dll" "$root/build/src/dxgi/dxgi.dll" \
    "$root/build/src/d3d10/d3d10core.dll" "$stage/"
mkdir -p "$out"
for dll in d3d11 dxgi d3d10core; do
    mv -T -- "$stage/$dll.dll" "$out/$dll.dll"
done
printf 'Patched DXVK is in %s\n' "$out"
