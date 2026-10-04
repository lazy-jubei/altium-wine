#!/bin/bash
# make-release.sh - package the kit for `curl | bash` installs. Writes files locally; uploading
# them (e.g. as GitHub release assets) is a separate, manual step.
#
# Usage:  bash make-release.sh --version v1.0 --url BASE_URL --modules DIR [--out DIR]
#
#   --version  release name, used in the asset file names
#   --url      where the assets will be downloadable, e.g.
#              https://github.com/OWNER/altium-wine/releases/download/v1.0
#   --modules  output of: bash build-patched-wine.sh --export DIR  (five files + SHA256SUMS)
#   --out      output folder (default: ./dist/VERSION)
#
# Output: install.sh (stamped with the URL and checksums), altium-wine-kit-VERSION.tar.gz,
# altium-wine-modules-VERSION.tar.gz, SHA256SUMS. Users then run:
#   curl -fsSL BASE_URL/install.sh | bash

set -eu

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="" URL="" MODULES="" OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --url)     URL="${2%/}"; shift 2 ;;
        --modules) MODULES="$2"; shift 2 ;;
        --out)     OUT="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ -n "$VERSION" ] && [ -n "$URL" ] && [ -n "$MODULES" ] || { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
case "$VERSION" in *[!A-Za-z0-9._-]*) echo "Version may only use letters, digits, . _ -" >&2; exit 1 ;; esac
OUT="${OUT:-$KIT_DIR/dist/$VERSION}"

for f in winemac.so d2d1.dll winhttp.dll wow64cpu.dll user32.dll SHA256SUMS; do
    [ -f "$MODULES/$f" ] || { echo "$MODULES/$f missing (make it with build-patched-wine.sh --export)" >&2; exit 1; }
done
( cd "$MODULES" && shasum -a 256 -c SHA256SUMS >/dev/null ) || { echo "Checksums in $MODULES don't match" >&2; exit 1; }

rm -rf "$OUT"; mkdir -p "$OUT"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# Kit: everything except logs, local settings and release output.
mkdir -p "$STAGE/kit"
( cd "$KIT_DIR" && tar -cf - --exclude ./logs --exclude ./dist --exclude ./config.local.sh \
    --exclude ./.git --exclude ./.github --exclude ./__pycache__ \
    --exclude '.DS_Store' --exclude '*.bak' --exclude '*.pyc' . ) | tar -xf - -C "$STAGE/kit"
mkdir -p "$STAGE/kit/logs"
KIT_TGZ="altium-wine-kit-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$OUT/$KIT_TGZ" -C "$STAGE" kit

# Patched Wine modules (LGPL; the patches that produce them are in the kit).
mkdir -p "$STAGE/modules"
cp "$MODULES"/winemac.so "$MODULES"/d2d1.dll "$MODULES"/winhttp.dll "$MODULES"/wow64cpu.dll \
   "$MODULES"/user32.dll "$MODULES"/SHA256SUMS "$STAGE/modules/"
[ -f "$MODULES/PATCHES" ] && cp "$MODULES/PATCHES" "$STAGE/modules/"
cp "$KIT_DIR/LICENSE" "$KIT_DIR/NOTICE" "$STAGE/modules/"
cp "$KIT_DIR/docs/wine-sources.md" "$STAGE/modules/"
MOD_TGZ="altium-wine-modules-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$OUT/$MOD_TGZ" -C "$STAGE" modules

sha() { shasum -a 256 "$1" | awk '{print $1}'; }
KIT_SHA="$(sha "$OUT/$KIT_TGZ")"
MOD_SHA="$(sha "$OUT/$MOD_TGZ")"

# Stamp install.sh; refuse if the stamp lines aren't exactly where expected.
stamp() { grep -cE "^$1=\"(dev)?\"\$" "$KIT_DIR/install.sh"; }
for v in KIT_VERSION RELEASE_URL KIT_SHA256 MODULES_SHA256; do
    [ "$(stamp $v)" = 1 ] || { echo "install.sh: stamp line for $v not found" >&2; exit 1; }
done
sed -e "s|^KIT_VERSION=\"dev\"\$|KIT_VERSION=\"$VERSION\"|" \
    -e "s|^RELEASE_URL=\"\"\$|RELEASE_URL=\"$URL\"|" \
    -e "s|^KIT_SHA256=\"\"\$|KIT_SHA256=\"$KIT_SHA\"|" \
    -e "s|^MODULES_SHA256=\"\"\$|MODULES_SHA256=\"$MOD_SHA\"|" \
    "$KIT_DIR/install.sh" > "$OUT/install.sh"
chmod +x "$OUT/install.sh"
bash -n "$OUT/install.sh"

( cd "$OUT" && shasum -a 256 install.sh "$KIT_TGZ" "$MOD_TGZ" > SHA256SUMS )
echo "Release $VERSION in $OUT:"
ls -la "$OUT"
echo
echo "Upload these files so they are reachable at $URL/<name>, then users run:"
echo "  curl -fsSL $URL/install.sh | bash"
