#!/bin/bash
# Build optional grid helper and loader; installs nothing into Altium.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LLVM="${LLVM_MINGW:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}/tools/llvm-mingw}"
OUTPUT="${1:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}/build/ad17-grid-cache}"
mkdir -p "$OUTPUT"
"$LLVM/bin/i686-w64-mingw32-gcc" -O2 -Wall -Wextra -Werror -shared \
    "$KIT_DIR/tools/ad17-grid-cache.c" "$KIT_DIR/tools/ad17-grid-cache.S" \
    -ld3dx9 -ld3d9 -o "$OUTPUT/ad17-grid-cache.dll"
"$LLVM/bin/i686-w64-mingw32-gcc" -O2 -Wall -Wextra -Werror -municode \
    "$KIT_DIR/tools/ad17-grid-cache-loader.c" -o "$OUTPUT/ad17-grid-cache-loader.exe"
(cd "$OUTPUT" && shasum -a 256 ad17-grid-cache.dll ad17-grid-cache-loader.exe > SHA256SUMS)
printf 'Built grid helper: %s\n' "$OUTPUT"
