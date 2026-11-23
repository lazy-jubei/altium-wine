#!/bin/bash
# build-patched-wine.sh - make $WORK_ROOT/wine-patched: a copy of the stock Gcenx wine-staging
# 11.16 bundle with the kit's fixes. The stock bundle is never modified.
#
# Usage:  bash build-patched-wine.sh [--modules DIR] [--export DIR] [--clean]
#
#   (none)          build winemac.so, win32u.so, d2d1.dll, dwrite.dll, winhttp.dll, msado15.dll (64- and 32-bit) and the
#                   32-bit d3dx9_43.dll, kernelbase.dll, d3d9.dll, wined3d.dll and wineserver from Wine 11.16 sources + patches/
#   --modules DIR   skip the build; take the files from DIR (e.g. a release download):
#                   winemac.so, win32u.so, d2d1.dll, dwrite.dll, winhttp.dll, msado15.dll, msado15-i386.dll,
#                   d3dx9_43-i386.dll, kernelbase-i386.dll, d3d9-i386.dll, wined3d-i386.dll, wineserver,
#                   altium-gdi-copy-arm64, altium-ui-ready.exe and
#                   optionally the already-patched
#                   wow64cpu.dll and user32.dll (then no python3 / Xcode tools
#                   are needed).
#                   DIR/SHA256SUMS, if present, is checked.
#   --export DIR    also copy the changed files + SHA256SUMS into DIR (for publishing)
#   --clean         delete the source/build trees and exit
#
# What changes compared with the stock bundle (lib/wine/...):
#   x86_64-unix/winemac.so      Mac window/input patches and transparent Metal/GDI child composition
#   x86_64-unix/win32u.so       matching DC-acquisition callback, Staging baseline and stock FreeType backend
#   x86_64-windows/d2d1.dll     patches/0003 + 0037 + 0038
#   x86_64-windows/dwrite.dll   patch 0042 (scaled glyph cache)
#   x86_64-windows/winhttp.dll  patches/0004
#   x86_64-windows/gdiplus.dll, i386-windows/gdiplus.dll patches/0031 (Staging baseline) + 0030/0032/0057 (font DPI/unit metrics, text bounds and cell metrics)
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
# Building needs Xcode Command Line Tools, MacPorts (bison), ~3 GB disk and ~15 min the first
# time (configure + host tools run under Rosetta). llvm-mingw is downloaded into tools/.
# Only modules that need nothing beyond the compiler are rebuilt, so every other part of the
# tested bundle stays byte-identical.

set -u

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$(uname -s)" = Linux ]; then
    exec bash "$KIT_DIR/tools/altium-wine-linux.sh" build-wine "$@"
fi
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
FREETYPE_REV="526ec5c47b9ebccc4754c85ac0c0cdf7c85a5e9b"
FREETYPE_SRC_URL="https://codeload.github.com/freetype/freetype/tar.gz/$FREETYPE_REV"
FREETYPE_SRC_SHA256="d24f53b60034dc5c48e90d122d432a8f04a05b9e0a98c8d8e49b4a759207ce2e"
SOURCE_PATCHES="0000-staging-winemac-no-flicker.patch 0002-winemac-clip-client-surfaces.patch 0003-d2d1-fast-redraw.patch 0037-d2d1-ordered-solid-batch.patch 0038-d2d1-text-aa-scaled.patch 0004-winhttp-infinite-receive-timeout.patch 0006-msado15-command-parameter-properties.patch 0007-winemac-activate-blocking-popup.patch 0008-d3dx9-staging-sync.patch 0009-d3dx9-effect-setrawvalue-struct-arrays.patch 0010-kernelbase-altiumms-pipe-write-event.patch 0011-kernelbase-staging-sync.patch 0012-winemac-separate-modal-owner.patch 0017-winemac-altium-panel-close-activation.patch 0020-winemac-altium-panel-queued-clicks.patch 0021-winemac-srgb-altium-windows.patch 0014-server-staging-sync.patch 0005-server-wakeup-epipe.patch 0013-server-signed-dpi-scaling.patch 0016-d3d9-staging-sync.patch 0015-d3d9-ad17-buffer-uploads.patch 0018-wined3d-staging-sync.patch 0019-d3d9-ring-upload-hints.patch 0022-wined3d-ad17-immediate-uploads.patch 0023-winemac-schematic-performance.patch 0029-winemac-main-thread-reentry.patch 0031-gdiplus-staging-sync.patch 0030-gdiplus-font-height-dpi.patch 0032-gdiplus-measure-string-height.patch 0057-gdiplus-windows-cell-metrics.patch 0033-winemac-accessibility-window.patch 0034-winemac-altium26-panel-close.patch 0035-winemac-altium-view-hide-activation.patch 0036-wined3d-vulkan-msaa-present.patch 0039-winemac-cross-screen-moves.patch 0040-winemac-zero-size-owner.patch 0042-dwrite-cache-scaled-glyphs.patch 0043-winemac-restore-clicked-window-order.patch 0045-winemac-dxmt-client-surfaces.patch 0047-winemac-altium-ctrl-shift-wheel.patch 0048-server-private-mapping-directory.patch 0050-winemac-metal-gdi-background.patch 0051-winemac-source-dib-copy-interface.patch 0052-win32u-host-vulkan-portability.patch 0053-win32u-staging-sync.patch 0054-winemac-retina-frame-padding.patch 0055-winemac-client-present-handoff.patch 0056-winemac-icon-premultiplied-alpha.patch 0058-winemac-retired-client-order.patch"
# built file | place in the bundle (relative to lib/wine) | name in a modules directory
TARGETS="dlls/winemac.drv/winemac.so|x86_64-unix/winemac.so|winemac.so
dlls/win32u/win32u.so|x86_64-unix/win32u.so|win32u.so
dlls/d2d1/x86_64-windows/d2d1.dll|x86_64-windows/d2d1.dll|d2d1.dll
dlls/dwrite/x86_64-windows/dwrite.dll|x86_64-windows/dwrite.dll|dwrite.dll
dlls/winhttp/x86_64-windows/winhttp.dll|x86_64-windows/winhttp.dll|winhttp.dll
dlls/gdiplus/x86_64-windows/gdiplus.dll|x86_64-windows/gdiplus.dll|gdiplus.dll
dlls/gdiplus/i386-windows/gdiplus.dll|i386-windows/gdiplus.dll|gdiplus-i386.dll
dlls/msado15/x86_64-windows/msado15.dll|x86_64-windows/msado15.dll|msado15.dll
dlls/msado15/i386-windows/msado15.dll|i386-windows/msado15.dll|msado15-i386.dll
dlls/d3dx9_43/i386-windows/d3dx9_43.dll|i386-windows/d3dx9_43.dll|d3dx9_43-i386.dll
dlls/kernelbase/i386-windows/kernelbase.dll|i386-windows/kernelbase.dll|kernelbase-i386.dll
dlls/d3d9/i386-windows/d3d9.dll|i386-windows/d3d9.dll|d3d9-i386.dll
dlls/wined3d/i386-windows/wined3d.dll|i386-windows/wined3d.dll|wined3d-i386.dll
server/wineserver|../../bin/wineserver|wineserver"
NATIVE_MODULE="altium-gdi-copy-arm64"
READINESS_MODULE="altium-ui-ready.exe"
BROWSER_MODULE="altium-browser-launch.exe"
BUILT_MODULES="$NATIVE_MODULE $READINESS_MODULE"
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
    # bison >= 3 (macOS's own is too old) comes from MacPorts.
    # shellcheck source=tools/macports.sh
    . "$(dirname "$0")/tools/macports.sh"
    macports_install bison || die "Installing bison with MacPorts failed (or use --modules DIR)."
    local bison_bin="$MACPORTS_BIN"

    # Rebuilding win32u without FreeType removes the normal font backend.
    # Only headers are needed here; Wine dynamically loads its bundled library.
    local ft_archive="$DL_DIR/freetype-$FREETYPE_REV.tar.gz"
    local ft_headers="$TOOLS_DIR/freetype-$FREETYPE_REV"
    local stock_lib="$STOCK_APP/Contents/Resources/wine/lib"
    [ -s "$stock_lib/libfreetype.6.dylib" ] || die "The stock Wine bundle lacks FreeType."
    if [ ! -s "$ft_archive" ]; then
        curl --proto '=https' -fL --retry 2 --progress-bar -o "$ft_archive.part" "$FREETYPE_SRC_URL" \
            && mv "$ft_archive.part" "$ft_archive" || die "FreeType headers download failed."
    fi
    [ "$(sha256_of "$ft_archive")" = "$FREETYPE_SRC_SHA256" ] || die "FreeType source checksum mismatch."
    if [ ! -s "$ft_headers/include/ft2build.h" ]; then
        tar -xzf "$ft_archive" -C "$TOOLS_DIR" || die "FreeType headers extract failed."
    fi

    # Relative flags survive configure and make even when WORK_ROOT contains spaces.
    ln -sfn "$stock_lib" "$TOOLS_DIR/freetype-runtime" || die "FreeType library staging failed."

    local llvm="$TOOLS_DIR/llvm-mingw"
    if [ ! -x "$llvm/bin/x86_64-w64-mingw32-clang" ]; then
        local url tag asset
        url="$(curl --proto '=https' -fsSIL -o /dev/null -w '%{url_effective}' https://github.com/mstorsjo/llvm-mingw/releases/latest)"
        tag="${url##*/tag/}"
        [ -n "$tag" ] && [ "$tag" != "$url" ] || die "Couldn't resolve the llvm-mingw release."
        asset="llvm-mingw-${tag}-ucrt-macos-universal.tar.xz"
        say "Downloading $asset (~100 MB)"
        curl --proto '=https' -fL --progress-bar -o "$TOOLS_DIR/$asset" "https://github.com/mstorsjo/llvm-mingw/releases/download/$tag/$asset" || die "llvm-mingw download failed."
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
        curl --proto '=https' -fL --progress-bar -o "$tarball.part" "$WINE_SRC_URL" && mv "$tarball.part" "$tarball" || die "Source download failed."
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
    if [ ! -f "$OBJ/Makefile" ] ||
        ! grep -q '^#define SONAME_LIBFREETYPE "@loader_path/../../libfreetype.6.dylib"' "$OBJ/include/config.h" ||
        ! grep -q '^#define HAVE_FT2BUILD_H 1' "$OBJ/include/config.h" ||
        ! grep -q '^#define SONAME_LIBVULKAN "@loader_path/../../libvulkan.1.dylib"' "$OBJ/include/config.h"; then
        say "Configuring (x86_64 under Rosetta; takes a few minutes)"
        ( cd "$OBJ" && arch -x86_64 env CC="/usr/bin/clang -arch x86_64" \
            FREETYPE_CFLAGS="-I../../tools/freetype-$FREETYPE_REV/include" \
            FREETYPE_LIBS="-L../../tools/freetype-runtime -lfreetype" \
            ac_cv_lib_soname_freetype=@loader_path/../../libfreetype.6.dylib \
            ac_cv_lib_soname_vulkan=@loader_path/../../libvulkan.1.dylib "$SRC/configure" \
            --build=x86_64-apple-darwin --enable-archs=i386,x86_64 --with-mingw --disable-tests \
            --without-x --with-freetype --without-gnutls --without-gstreamer --without-sdl \
            --with-vulkan --without-opencl --without-pcap --without-pcsclite --without-cups \
            --without-inotify --without-krb5 --without-gssapi --without-netapi --without-usb \
            --without-v4l2 --without-sane --without-pulse --without-oss --without-alsa \
            --without-capi --without-dbus --without-gphoto --without-udev --without-wayland \
            --without-ffmpeg --without-gettext --without-gettextpo \
        ) > "$LOG_DIR/$TS-configure.log" 2>&1 || die "configure failed (see logs/$TS-configure.log)"
    fi

    grep -q '^#define HAVE_FT2BUILD_H 1' "$OBJ/include/config.h" &&
        grep -q '^#define SONAME_LIBFREETYPE "@loader_path/../../libfreetype.6.dylib"' "$OBJ/include/config.h" &&
        grep -q '^#define SONAME_LIBVULKAN "@loader_path/../../libvulkan.1.dylib"' "$OBJ/include/config.h" \
        || die "Rebuilt win32u requires the stock FreeType and Vulkan backends."

    local ncpu targets="" t
    ncpu="${ALTIUM_WINE_BUILD_JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
    case "$ncpu" in ''|*[!0-9]*|0) die "ALTIUM_WINE_BUILD_JOBS must be a positive integer." ;; esac
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
    "$llvm/bin/x86_64-w64-mingw32-clang" -O2 "$KIT_DIR/tools/altium-ui-ready.c" \
        -o "$MODULES_DIR/$READINESS_MODULE" -luser32 -ladvapi32 || die "UI readiness helper build failed"
    "$llvm/bin/x86_64-w64-mingw32-clang" -O2 -s -municode -mwindows "$KIT_DIR/tools/altium-browser-launch.c" \
        -o "$MODULES_DIR/$BROWSER_MODULE" -lshell32 || die "Installer browser helper build failed"
    codesign -s - -f "$MODULES_DIR/$NATIVE_MODULE" 2>/dev/null || die "Could not sign native GDI worker"
    codesign -s - -f "$MODULES_DIR/wineserver" 2>/dev/null || die "Could not sign the rebuilt wineserver"
    # The unstripped d3dx9 is 2.6 MB (the stock one is 0.6 MB); the other modules ship as built.
    "$llvm/bin/llvm-strip" --strip-unneeded "$MODULES_DIR/d3dx9_43-i386.dll" 2>/dev/null || true
    # shellcheck disable=SC2086
    ( cd "$MODULES_DIR" && shasum -a 256 $BUILT_MODULES "$BROWSER_MODULE" > SHA256SUMS )
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

patched_wine_in_use() {
    local app image output status images=()
    for app in "$PATCHED_ROOT"/Wine*.app "$PATCHED_ROOT"/dxmt/Wine*.app; do
        [ -d "$app" ] || continue
        for image in bin/wine bin/wineserver lib/wine/x86_64-unix/ntdll.so \
            lib/wine/x86_64-unix/win32u.so lib/wine/x86_64-unix/winemac.so; do
            image="$app/Contents/Resources/wine/$image"
            [ ! -f "$image" ] || images+=("$image")
        done
    done
    [ ${#images[@]} -gt 0 ] || return 1
    # Windows processes can replace their Unix process name with X2.EXE or
    # another Windows path. Inspect mapped files rather than the process name.
    output="$(/usr/sbin/lsof -t "${images[@]}" 2>&1)"
    status=$?
    # lsof can return 1 when only some requested images are open.
    if printf '%s\n' "$output" | grep -qE '^[0-9]+$'; then return 0; fi
    [ "$status" != 0 ] || return 0
    [ "$status" = 1 ] && [ -z "$output" ] && return 1
    die "Could not check whether $PATCHED_ROOT is in use: $output"
}

if patched_wine_in_use; then
    die "Wine from $PATCHED_ROOT is running. Close its Altium or installer before updating it."
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
[ -f "$MODULES_DIR/$READINESS_MODULE" ] || die "$MODULES_DIR/$READINESS_MODULE missing"
cp "$MODULES_DIR/$READINESS_MODULE" "$BINW/$READINESS_MODULE" || die "Copy UI readiness helper failed"
chmod 755 "$BINW/$READINESS_MODULE"
if [ -f "$MODULES_DIR/$BROWSER_MODULE" ]; then
    install -m 755 "$MODULES_DIR/$BROWSER_MODULE" "$BINW/$BROWSER_MODULE" || die "Copy installer browser helper failed"
fi
chmod 755 "$BINW/wineserver" || die "Could not set wineserver permissions"
codesign -s - -f "$BINW/wineserver" 2>/dev/null || die "Could not sign wineserver"

# Keep DXMT's builtin DLLs in a separate copy so AD17 and DXVK keep the
# normal Wine Direct3D modules. Both copies use the same wineserver build.
if [ -d "$MODULES_DIR/dxmt" ]; then
    . "$KIT_DIR/tools/dxmt-files.sh"
    for module in $DXMT_FILES; do
        [ -s "$MODULES_DIR/$module" ] || die "DXMT module missing: $module"
    done
    if [ "$(uname -m)" = x86_64 ] && [ "$(sysctl -in hw.optional.arm64)" != 1 ]; then
        DXMT_APP="$NEW/dxmt/$(basename "$STOCK_APP")"
        ditto "$DEST_APP" "$DXMT_APP" || die "Could not copy Wine for DXMT"
        dxmt_wine="$DXMT_APP/Contents/Resources/wine"
        dxmt_modules="$MODULES_DIR/dxmt"
        cp "$dxmt_modules/"{d3d10core,d3d11,dxgi,winemetal}.dll "$dxmt_wine/lib/wine/x86_64-windows/" \
            || die "Could not install DXMT Windows modules"
        cp "$dxmt_modules/winemetal.so" "$dxmt_wine/lib/wine/x86_64-unix/" \
            || die "Could not install the DXMT native module"
        cp "$dxmt_modules/metal-init.dylib" "$dxmt_wine/bin/" || die "Could not install Metal initialization"
        cp "$dxmt_modules/"{LICENSE,COPYING.LIB,LICENSE.OLD} "$NEW/dxmt/" || die "Could not install DXMT licenses"
        say "Assembled the optional Intel DXMT runtime"
    fi
fi

cp "$WINE_ROOT/VERSION" "$NEW/VERSION"
{
    echo "built: $(date)"
    echo "base:  $FLAVOR $VER  ($(basename "$STOCK_APP"))"
    echo "source patches: $SOURCE_PATCHES"
    echo "binary patches: wow64cpu-rosetta-trampoline.py, pe-add-stub-exports.py InheritWindowMonitor=1"
    echo "changed files (sha256):"
    ( cd "$LIBW" && shasum -a 256 x86_64-unix/winemac.so x86_64-unix/win32u.so x86_64-windows/d2d1.dll x86_64-windows/dwrite.dll x86_64-windows/winhttp.dll \
        x86_64-windows/gdiplus.dll i386-windows/gdiplus.dll x86_64-windows/msado15.dll i386-windows/msado15.dll i386-windows/d3dx9_43.dll i386-windows/kernelbase.dll i386-windows/d3d9.dll i386-windows/wined3d.dll \
        x86_64-windows/wow64cpu.dll x86_64-windows/user32.dll ) | sed 's/^/  /'
    ( cd "$BINW" && shasum -a 256 wineserver "$NATIVE_MODULE" "$READINESS_MODULE"
      if [ -f "$BROWSER_MODULE" ]; then shasum -a 256 "$BROWSER_MODULE"; fi ) | sed 's/^/  /'
    if [ -d "$MODULES_DIR/dxmt" ]; then
        echo "DXMT package inputs (sha256):"
        ( cd "$MODULES_DIR" && shasum -a 256 $DXMT_FILES ) | sed 's/^/  /'
    fi
} > "$NEW/PATCHES"

# Check again in case Wine started while the replacement was being assembled.
if patched_wine_in_use; then
    die "Wine from $PATCHED_ROOT is running (Altium?). Close it and run this again; the new bundle is in $NEW."
fi
if [ -d "$PATCHED_ROOT" ]; then
    rm -rf "$PATCHED_ROOT.old"
    mv "$PATCHED_ROOT" "$PATCHED_ROOT.old" || die "Couldn't move the old bundle aside"
fi
if ! mv "$NEW" "$PATCHED_ROOT"; then
    if [ -d "$PATCHED_ROOT.old" ]; then
        mv "$PATCHED_ROOT.old" "$PATCHED_ROOT" || warn "The previous bundle is in $PATCHED_ROOT.old"
    fi
    die "Couldn't move the new bundle into place"
fi
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
    cp "$PATCHED_ROOT/$(basename "$STOCK_APP")/Contents/Resources/wine/bin/$READINESS_MODULE" "$EXPORT_DIR/" || die "UI readiness helper export failed"
    export_modules="$BUILT_MODULES"
    if [ -f "${L%/lib/wine}/bin/$BROWSER_MODULE" ]; then
        cp "${L%/lib/wine}/bin/$BROWSER_MODULE" "$EXPORT_DIR/" || die "Installer browser helper export failed"
        export_modules="$export_modules $BROWSER_MODULE"
    fi
    cp "$PATCHED_ROOT/PATCHES" "$EXPORT_DIR/PATCHES"
    # shellcheck disable=SC2086
    ( cd "$EXPORT_DIR" && shasum -a 256 $export_modules wow64cpu.dll user32.dll > SHA256SUMS )
    say "Exported modules to $EXPORT_DIR"
fi

say "Done. Patched Wine: $PATCHED_ROOT/$(basename "$STOCK_APP")"
cat "$PATCHED_ROOT/PATCHES"
cp "$LOG" "$LOG_DIR/LATEST-summary.txt"
