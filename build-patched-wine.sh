#!/bin/bash
# build-patched-wine.sh - make $WORK_ROOT/wine-patched: a copy of the stock Gcenx wine-staging
# 11.16 bundle with the kit's fixes. The stock bundle is never modified.
#
# Usage:  bash build-patched-wine.sh [--modules DIR] [--export DIR] [--clean]
#
#   (none)          build winemac.so, d2d1.dll, winhttp.dll, msado15.dll (64- and 32-bit) and the
#                   32-bit d3dx9_43.dll, kernelbase.dll, d3d9.dll, wined3d.dll and wineserver from Wine 11.16 sources + patches/
#   --modules DIR   skip the build; take the files from DIR (e.g. a release download):
#                   winemac.so, d2d1.dll, winhttp.dll, msado15.dll, msado15-i386.dll,
#                   d3dx9_43-i386.dll, kernelbase-i386.dll, d3d9-i386.dll, wined3d-i386.dll, wineserver,
#                   altium-gdi-copy-arm64 and
#                   optionally the already-patched
#                   wow64cpu.dll and user32.dll (then no python3 / Xcode tools
#                   are needed).
#                   DIR/SHA256SUMS, if present, is checked.
#   --export DIR    also copy all thirteen changed files + SHA256SUMS into DIR (for publishing)
#   --clean         delete the source/build trees and exit
#
# What changes compared with the stock bundle (lib/wine/...):
#   x86_64-unix/winemac.so      patches/0000 (wine-staging no-flicker, as in the stock build) + 0002 + 0007 + 0012 + 0017 + 0020 + 0021 + 0023
#   x86_64-windows/d2d1.dll     patches/0003
#   x86_64-windows/winhttp.dll  patches/0004
#   x86_64-windows/msado15.dll, i386-windows/msado15.dll  patches/0006 (Altium 17's library server)
#   i386-windows/d3dx9_43.dll   patches/0008 (wine-staging's d3dx9 changes) + 0009 (SetRawValue on
#                               structure arrays: Altium 17's lit 3D view was black)
#   i386-windows/kernelbase.dll patches/0010 (AltiumMS synchronous pipe-write completion) + 0011 (Staging baseline)
#   x86_64-windows/wow64cpu.dll patches/wow64cpu-rosetta-trampoline.py (binary patch)
#   x86_64-windows/user32.dll   patches/pe-add-stub-exports.py InheritWindowMonitor=1 (binary patch)
#   i386-windows/d3d9.dll       patches/0016 (Staging baseline) + 0015 + 0019 (AD17 ring uploads)
#   i386-windows/wined3d.dll    patches/0018 (Staging baseline) + 0019 + 0022 (AD17 uploads)
#   bin/wineserver              patches/0014 (Staging baseline) + 0005 (EPIPE) + 0013 (signed DPI)
#
# Building needs Xcode Command Line Tools, Homebrew (bison), ~3 GB disk and ~15 min the first
# time (configure + host tools run under Rosetta). llvm-mingw is downloaded into tools/.
# Only modules that need nothing beyond the compiler are rebuilt, so every other part of the
# tested bundle stays byte-identical.

set -u

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$KIT_DIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"
WORK_ROOT="${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}"
# shellcheck source=config.sh
[ -f "$KIT_DIR/config.sh" ] && . "$KIT_DIR/config.sh"
[ -f "$KIT_DIR/config.local.sh" ] && . "$KIT_DIR/config.local.sh"

WINE_ROOT="$WORK_ROOT/wine"
PATCHED_ROOT="${PATCHED_ROOT_OVERRIDE:-$WORK_ROOT/wine-patched}"
TOOLS_DIR="$WORK_ROOT/tools"
BUILD_ROOT="$WORK_ROOT/build"
DL_DIR="$WORK_ROOT/downloads"
mkdir -p "$LOG_DIR" "$TOOLS_DIR" "$BUILD_ROOT" "$DL_DIR"
LOG="$LOG_DIR/$TS-build-patched.log"
exec > >(trap '' INT; exec tee -a "$LOG") 2>&1

say()  { printf '\033[1;34m==>\033[0m [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*"; cp "$LOG" "$LOG_DIR/LATEST-summary.txt" 2>/dev/null; exit 1; }
sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

WINE_VER="11.16"
WINE_SRC_URL="https://dl.winehq.org/wine/source/11.x/wine-$WINE_VER.tar.xz"
WINE_SRC_SHA256="c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f"
SOURCE_PATCHES="0000-staging-winemac-no-flicker.patch 0002-winemac-clip-client-surfaces.patch 0003-d2d1-fast-redraw.patch 0004-winhttp-infinite-receive-timeout.patch 0006-msado15-command-parameter-properties.patch 0007-winemac-activate-blocking-popup.patch 0008-d3dx9-staging-sync.patch 0009-d3dx9-effect-setrawvalue-struct-arrays.patch 0010-kernelbase-altiumms-pipe-write-event.patch 0011-kernelbase-staging-sync.patch 0012-winemac-separate-modal-owner.patch 0017-winemac-altium-panel-close-activation.patch 0020-winemac-altium-panel-queued-clicks.patch 0021-winemac-srgb-altium-windows.patch 0014-server-staging-sync.patch 0005-server-wakeup-epipe.patch 0013-server-signed-dpi-scaling.patch 0016-d3d9-staging-sync.patch 0015-d3d9-ad17-buffer-uploads.patch 0018-wined3d-staging-sync.patch 0019-d3d9-ring-upload-hints.patch 0022-wined3d-ad17-immediate-uploads.patch 0023-winemac-schematic-performance.patch"
# built file | place in the bundle (relative to lib/wine) | name in a modules directory
TARGETS="dlls/winemac.drv/winemac.so|x86_64-unix/winemac.so|winemac.so
dlls/d2d1/x86_64-windows/d2d1.dll|x86_64-windows/d2d1.dll|d2d1.dll
dlls/winhttp/x86_64-windows/winhttp.dll|x86_64-windows/winhttp.dll|winhttp.dll
dlls/msado15/x86_64-windows/msado15.dll|x86_64-windows/msado15.dll|msado15.dll
dlls/msado15/i386-windows/msado15.dll|i386-windows/msado15.dll|msado15-i386.dll
dlls/d3dx9_43/i386-windows/d3dx9_43.dll|i386-windows/d3dx9_43.dll|d3dx9_43-i386.dll
dlls/kernelbase/i386-windows/kernelbase.dll|i386-windows/kernelbase.dll|kernelbase-i386.dll
dlls/d3d9/i386-windows/d3d9.dll|i386-windows/d3d9.dll|d3d9-i386.dll
dlls/wined3d/i386-windows/wined3d.dll|i386-windows/wined3d.dll|wined3d-i386.dll
server/wineserver|../../bin/wineserver|wineserver"
NATIVE_MODULE="altium-gdi-copy-arm64"
BUILT_MODULES="$NATIVE_MODULE"
for t in $TARGETS; do BUILT_MODULES="$BUILT_MODULES ${t##*|}"; done

SRC="$BUILD_ROOT/src-wine-$WINE_VER"
OBJ="$BUILD_ROOT/obj-wine-$WINE_VER"

MODULES_DIR=""
EXPORT_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --modules) MODULES_DIR="${2:?--modules needs a directory}"; shift 2 ;;
        --export)  EXPORT_DIR="${2:?--export needs a directory}"; shift 2 ;;
        --clean)   say "Removing $SRC and $OBJ"; rm -rf "$SRC" "$OBJ"; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# ---- checks ----------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || die "macOS only."
arch -x86_64 /usr/bin/true 2>/dev/null || die "Rosetta 2 missing. Run: softwareupdate --install-rosetta"

STOCK_APP=""
for a in "$WINE_ROOT"/Wine*.app; do [ -x "$a/Contents/Resources/wine/bin/wine" ] && STOCK_APP="$a" && break; done
[ -n "$STOCK_APP" ] || die "No stock Wine in $WINE_ROOT. Run: bash altium-wine.sh setup"
read -r FLAVOR VER < "$WINE_ROOT/VERSION" || die "Missing $WINE_ROOT/VERSION"
[ "$FLAVOR $VER" = "staging $WINE_VER" ] || die "The patches are for wine-staging $WINE_VER; $WINE_ROOT has $FLAVOR $VER. Set WINE_FLAVOR=staging WINE_VERSION=$WINE_VER in config.sh and run: bash altium-wine.sh setup --force-wine"
say "Stock bundle: $STOCK_APP ($FLAVOR $VER)"

# ---- source-built modules ---------------------------------------
build_modules() {
    xcode-select -p >/dev/null 2>&1 || die "Xcode Command Line Tools missing. Run: xcode-select --install (or use --modules DIR)"
    local brew="" b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && brew="$b" && break; done
    [ -n "$brew" ] || die "Homebrew is needed for bison >= 3 (https://brew.sh), or use --modules DIR."
    "$brew" list bison >/dev/null 2>&1 || { say "brew install bison"; "$brew" install bison || die "bison install failed"; }
    local bison_bin
    bison_bin="$("$brew" --prefix bison)/bin"

    local llvm="$TOOLS_DIR/llvm-mingw"
    if [ ! -x "$llvm/bin/x86_64-w64-mingw32-clang" ]; then
        local url tag asset
        url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/mstorsjo/llvm-mingw/releases/latest)"
        tag="${url##*/tag/}"
        [ -n "$tag" ] && [ "$tag" != "$url" ] || die "Couldn't resolve the llvm-mingw release."
        asset="llvm-mingw-${tag}-ucrt-macos-universal.tar.xz"
        say "Downloading $asset (~100 MB)"
        curl -fL --progress-bar -o "$TOOLS_DIR/$asset" "https://github.com/mstorsjo/llvm-mingw/releases/download/$tag/$asset" || die "llvm-mingw download failed."
        rm -rf "$llvm" "$TOOLS_DIR/${asset%.tar.xz}"
        tar -xJf "$TOOLS_DIR/$asset" -C "$TOOLS_DIR" || die "llvm-mingw extract failed."
        mv "$TOOLS_DIR/${asset%.tar.xz}" "$llvm"
        xattr -dr com.apple.quarantine "$llvm" 2>/dev/null || true
        rm -f "$TOOLS_DIR/$asset"
    fi
    # llvm-mingw's bin also has a "clang"; the host compiler must be Apple's (set via CC below).
    export PATH="$llvm/bin:$bison_bin:$PATH"

    local tarball="$DL_DIR/wine-$WINE_VER.tar.xz"
    if [ ! -s "$tarball" ]; then
        say "Downloading Wine $WINE_VER sources (~30 MB)"
        curl -fL --progress-bar -o "$tarball.part" "$WINE_SRC_URL" && mv "$tarball.part" "$tarball" || die "Source download failed."
    fi
    [ "$(sha256_of "$tarball")" = "$WINE_SRC_SHA256" ] || { rm -f "$tarball"; die "Wine source checksum mismatch; deleted it, try again."; }

    # Fresh sources every time, so the patches always apply to pristine files. The object
    # tree is kept: make only rebuilds what the patches touched.
    say "Unpacking and patching sources"
    rm -rf "$SRC" "$SRC.tmp"; mkdir -p "$SRC.tmp"
    tar -xJf "$tarball" -C "$SRC.tmp" || die "Source extract failed."
    mv "$SRC.tmp/wine-$WINE_VER" "$SRC"; rmdir "$SRC.tmp"
    local p
    for p in $SOURCE_PATCHES; do
        ( cd "$SRC" && patch -p1 -s -N < "$KIT_DIR/patches/$p" ) || die "Patch failed: $p"
        echo "  applied $p"
    done

    mkdir -p "$OBJ"
    if [ ! -f "$OBJ/Makefile" ]; then
        say "Configuring (x86_64 under Rosetta; takes a few minutes)"
        ( cd "$OBJ" && arch -x86_64 env CC="/usr/bin/clang -arch x86_64" "$SRC/configure" \
            --build=x86_64-apple-darwin --enable-archs=i386,x86_64 --with-mingw --disable-tests \
            --without-x --without-freetype --without-gnutls --without-gstreamer --without-sdl \
            --without-vulkan --without-opencl --without-pcap --without-pcsclite --without-cups \
            --without-inotify --without-krb5 --without-gssapi --without-netapi --without-usb \
            --without-v4l2 --without-sane --without-pulse --without-oss --without-alsa \
            --without-capi --without-dbus --without-gphoto --without-udev --without-wayland \
            --without-ffmpeg --without-gettext --without-gettextpo \
        ) > "$LOG_DIR/$TS-configure.log" 2>&1 || die "configure failed (see logs/$TS-configure.log)"
    fi

    local ncpu targets="" t
    ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
    for t in $TARGETS; do targets="$targets ${t%%|*}"; done
    say "Building:$targets"
    # shellcheck disable=SC2086
    ( cd "$OBJ" && arch -x86_64 make -j"$ncpu" $targets ) > "$LOG_DIR/$TS-make.log" 2>&1 \
        || die "Build failed (see logs/$TS-make.log)"
    MODULES_DIR="$BUILD_ROOT/modules-$TS"
    mkdir -p "$MODULES_DIR"
    for t in $TARGETS; do cp "$OBJ/${t%%|*}" "$MODULES_DIR/${t##*|}" || die "Missing build output ${t%%|*}"; done
    /usr/bin/clang -arch arm64 -O3 "$SRC/dlls/winemac.drv/native_gdi_worker.c" -o "$MODULES_DIR/$NATIVE_MODULE" \
        || die "Native GDI worker build failed"
    codesign -s - -f "$MODULES_DIR/$NATIVE_MODULE" 2>/dev/null || die "Could not sign native GDI worker"
    codesign -s - -f "$MODULES_DIR/wineserver" 2>/dev/null || die "Could not sign the rebuilt wineserver"
    # The unstripped d3dx9 is 2.6 MB (the stock one is 0.6 MB); the other modules ship as built.
    "$llvm/bin/llvm-strip" --strip-unneeded "$MODULES_DIR/d3dx9_43-i386.dll" 2>/dev/null || true
    # shellcheck disable=SC2086
    ( cd "$MODULES_DIR" && shasum -a 256 $BUILT_MODULES > SHA256SUMS )
}

if [ -n "$MODULES_DIR" ]; then
    [ -d "$MODULES_DIR" ] || die "No such directory: $MODULES_DIR"
    if [ -f "$MODULES_DIR/SHA256SUMS" ]; then
        ( cd "$MODULES_DIR" && shasum -a 256 -c SHA256SUMS ) || die "Checksum mismatch in $MODULES_DIR"
    else
        warn "$MODULES_DIR has no SHA256SUMS; using the files unchecked."
    fi
else
    build_modules
fi

# ---- assemble a new bundle next to the old one, then swap ------------------
NEW="$PATCHED_ROOT.new-$TS"
say "Assembling patched bundle"
rm -rf "$NEW"; mkdir -p "$NEW"
DEST_APP="$NEW/$(basename "$STOCK_APP")"
ditto "$STOCK_APP" "$DEST_APP" || die "Copy failed"
LIBW="$DEST_APP/Contents/Resources/wine/lib/wine"
STOCKW="$STOCK_APP/Contents/Resources/wine/lib/wine"

BINW="$DEST_APP/Contents/Resources/wine/bin"
if [ -f "$MODULES_DIR/wow64cpu.dll" ] && [ -f "$MODULES_DIR/user32.dll" ]; then
    cp "$MODULES_DIR/wow64cpu.dll" "$MODULES_DIR/user32.dll" "$LIBW/x86_64-windows/" || die "Copy failed"
    echo "  installed prepatched wow64cpu.dll and user32.dll"
else
    # /usr/bin/python3 is only a stub until the Xcode Command Line Tools are installed.
    xcode-select -p >/dev/null 2>&1 || die "The binary patchers need python3: run xcode-select --install (or use a --modules dir with wow64cpu.dll and user32.dll)"
    python3 "$KIT_DIR/patches/wow64cpu-rosetta-trampoline.py" "$STOCKW/x86_64-windows/wow64cpu.dll" "$LIBW/x86_64-windows/wow64cpu.dll" \
        || die "wow64cpu patch failed"
    python3 "$KIT_DIR/patches/pe-add-stub-exports.py" "$STOCKW/x86_64-windows/user32.dll" "$LIBW/x86_64-windows/user32.dll" InheritWindowMonitor=1 \
        || die "user32 patch failed"

fi
for t in $TARGETS; do
    f="${t##*|}"; rel="${t#*|}"; rel="${rel%|*}"; dst="$LIBW/$rel"
    [ -f "$dst" ] || die "Unexpected bundle layout: $dst missing"
    [ -f "$MODULES_DIR/$f" ] || die "$MODULES_DIR/$f missing"
    cp "$MODULES_DIR/$f" "$dst" || die "Copy $f failed"
    echo "  installed $f -> lib/wine/$rel"
done
[ -f "$MODULES_DIR/$NATIVE_MODULE" ] || die "$MODULES_DIR/$NATIVE_MODULE missing"
cp "$MODULES_DIR/$NATIVE_MODULE" "$BINW/$NATIVE_MODULE" || die "Copy native GDI worker failed"
chmod 755 "$BINW/$NATIVE_MODULE" || die "Could not set native worker permissions"
chmod 755 "$BINW/wineserver" || die "Could not set wineserver permissions"
codesign -s - -f "$BINW/wineserver" 2>/dev/null || die "Could not sign wineserver"

cp "$WINE_ROOT/VERSION" "$NEW/VERSION"
{
    echo "built: $(date)"
    echo "base:  $FLAVOR $VER  ($(basename "$STOCK_APP"))"
    echo "source patches: $SOURCE_PATCHES"
    echo "binary patches: wow64cpu-rosetta-trampoline.py, pe-add-stub-exports.py InheritWindowMonitor=1"
    echo "changed files (sha256):"
    ( cd "$LIBW" && shasum -a 256 x86_64-unix/winemac.so x86_64-windows/d2d1.dll x86_64-windows/winhttp.dll \
        x86_64-windows/msado15.dll i386-windows/msado15.dll i386-windows/d3dx9_43.dll i386-windows/kernelbase.dll i386-windows/d3d9.dll i386-windows/wined3d.dll \
        x86_64-windows/wow64cpu.dll x86_64-windows/user32.dll ) | sed 's/^/  /'
    ( cd "$BINW" && shasum -a 256 wineserver "$NATIVE_MODULE" ) | sed 's/^/  /'
} > "$NEW/PATCHES"

# Replacing the bundle under a running Wine would mix old and new modules in one session.
# Inspect executable names, not arbitrary shell arguments mentioning the bundle.
if ps -axo stat=,comm= | awk -v root="$PATCHED_ROOT/" '
    $1 !~ /[EZ]/ { sub(/^[ \t]*[^ \t]+[ \t]+/, ""); if (index($0, root) == 1) found = 1 }
    END { exit !found }'; then
    die "Wine from $PATCHED_ROOT is running (Altium?). Close it and run this again; the new bundle is in $NEW."
fi
if [ -d "$PATCHED_ROOT" ]; then
    rm -rf "$PATCHED_ROOT.old"
    mv "$PATCHED_ROOT" "$PATCHED_ROOT.old" || die "Couldn't move the old bundle aside"
fi
mv "$NEW" "$PATCHED_ROOT" || die "Couldn't move the new bundle into place"
rm -rf "$PATCHED_ROOT.old"

if [ -n "$EXPORT_DIR" ]; then
    mkdir -p "$EXPORT_DIR"
    L="$PATCHED_ROOT/$(basename "$STOCK_APP")/Contents/Resources/wine/lib/wine"
    for t in $TARGETS; do
        rel="${t#*|}"; rel="${rel%|*}"
        cp "$L/$rel" "$EXPORT_DIR/${t##*|}" || die "Export failed"
    done
    cp "$L/x86_64-windows/wow64cpu.dll" "$L/x86_64-windows/user32.dll" "$EXPORT_DIR/" \
        || die "Export failed"
    cp "$PATCHED_ROOT/$(basename "$STOCK_APP")/Contents/Resources/wine/bin/$NATIVE_MODULE" "$EXPORT_DIR/" || die "Native worker export failed"
    cp "$PATCHED_ROOT/PATCHES" "$EXPORT_DIR/PATCHES"
    # shellcheck disable=SC2086
    ( cd "$EXPORT_DIR" && shasum -a 256 $BUILT_MODULES wow64cpu.dll user32.dll > SHA256SUMS )
    say "Exported modules to $EXPORT_DIR"
fi

say "Done. Patched Wine: $PATCHED_ROOT/$(basename "$STOCK_APP")"
cat "$PATCHED_ROOT/PATCHES"
cp "$LOG" "$LOG_DIR/LATEST-summary.txt"
