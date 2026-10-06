#!/bin/bash
# altium-wine.sh - Altium Designer on macOS (Apple Silicon) with plain Wine, no CrossOver.
#
# Usage:  bash altium-wine.sh [command]
#
#   (none)        setup if needed, install winetricks deps if needed, then run the installer
#   setup         download Wine, create the prefix, apply base config  (--force-wine re-downloads)
#   deps [verbs]  install winetricks verbs (default: WINETRICKS_VERBS in config.sh)
#   install [DIR] run the Altium offline installer (Installer.Exe in DIR, default: the folder
#                 that contains this kit) with debug logging
#   run           launch the installed Altium Designer (X2.EXE, or DXP.EXE for 17 and older)
#   hang-dump     backtrace every Wine thread; run this from a 2nd Terminal while something hangs
#   doctor        write system / Wine / prefix diagnostics to logs/
#   wine ARGS...  run any command in the Altium prefix, e.g.  wine winecfg   or   wine regedit
#   launcher [DIR] create "Altium Designer (Wine).app" in DIR (default ~/Applications)
#   reset         delete the Wine prefix (keeps the downloaded Wine)
#   uninstall     delete everything under WORK_ROOT (Wine, prefix, Altium, downloads) and the launcher
#   help
#
# Every command writes logs to ./logs; logs/LATEST-summary.txt is the short version.
# Written for macOS's stock /bin/bash 3.2 (no bash-4 features).

set -u

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALTIUM_DIR="$(cd "$KIT_DIR/.." && pwd)"
LOG_DIR="$KIT_DIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"

# ---- defaults (config.sh overrides) ---------------------------------------
WORK_ROOT="${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}"
WINE_FLAVOR="staging"
WINE_VERSION="latest"
PINNED_WINE_VERSION="11.16"
WINDOWS_VERSION="win10"
WINETRICKS_VERBS="corefonts"
EXTRA_DLLOVERRIDES=""
WINEDEBUG_INSTALL="+timestamp,+pid,+tid,+seh,+loaddll,+process"
WINEDEBUG_RUN="+timestamp,+pid,+tid,+seh,+loaddll"
USE_PATCHED_WINE=0
DWM_COMPOSITION_OFF=0
# shellcheck source=config.sh
[ -f "$KIT_DIR/config.sh" ] && . "$KIT_DIR/config.sh"
# Machine-specific settings (written by install.sh, kept across kit updates).
[ -f "$KIT_DIR/config.local.sh" ] && . "$KIT_DIR/config.local.sh"

PREFIX="$WORK_ROOT/prefix"
WINE_ROOT="$WORK_ROOT/wine"
PATCHED_ROOT="$WORK_ROOT/wine-patched"
DL_DIR="$WORK_ROOT/downloads"
TOOLS_DIR="$WORK_ROOT/tools"
WINETRICKS="$TOOLS_DIR/winetricks"
GCENX_REPO="https://github.com/Gcenx/macOS_Wine_builds"

mkdir -p "$LOG_DIR" "$WORK_ROOT" "$DL_DIR" "$TOOLS_DIR"
SESSION_LOG="$LOG_DIR/$TS-session.log"
# Full transcript of everything this script prints (Wine's own output goes to per-run logs).
# tee ignores Ctrl+C so the script can still kill Wine and write the summary after an interrupt.
exec > >(trap '' INT; exec tee -a "$SESSION_LOG") 2>&1

# ---- output helpers --------------------------------------------------------
say()   { printf '\033[1;34m==>\033[0m [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*"; exit 1; }

ask_yes() {  # ask_yes "question" -> 0 if user typed y/yes
    local reply
    printf '%s [y/N] ' "$1"
    read -r reply || return 1
    case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

find_brew() {
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$b" ] && { echo "$b"; return 0; }
    done
    command -v brew 2>/dev/null
}

# ---- platform checks -------------------------------------------------------
check_platform() {
    [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS."
    local apple_silicon
    apple_silicon="$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)"
    if [ "$apple_silicon" = "1" ]; then
        if ! arch -x86_64 /usr/bin/true 2>/dev/null; then
            warn "Rosetta 2 is not installed. Wine's x86 code needs it."
            if ask_yes "Install Rosetta 2 now? (runs Apple's installer and accepts its license)"; then
                softwareupdate --install-rosetta --agree-to-license || die "Rosetta install failed."
            else
                die "Rosetta 2 is required. Install it with: softwareupdate --install-rosetta"
            fi
        fi
    fi
    local free_gb
    free_gb="$(df -g "$HOME" | awk 'NR==2 {print $4}')"
    if [ -n "$free_gb" ] && [ "$free_gb" -lt 25 ] 2>/dev/null; then
        warn "Only ${free_gb} GB free in your home volume; Wine + Altium need ~20 GB."
    fi
}

# ---- Wine bundle -----------------------------------------------------------
find_wine_app() {  # find_wine_app DIR -> prints path of first Wine*.app with a wine binary
    local app
    for app in "$1"/Wine*.app; do
        [ -x "$app/Contents/Resources/wine/bin/wine" ] && { echo "$app"; return 0; }
    done
    return 1
}

select_wine() {  # sets WINE_APP / WINE / WINESERVER; returns 1 if nothing installed
    local app=""
    if [ "$USE_PATCHED_WINE" = "1" ]; then
        app="$(find_wine_app "$PATCHED_ROOT")" || return 1  # setup builds it
    else
        app="$(find_wine_app "$WINE_ROOT")" || return 1
    fi
    WINE_APP="$app"
    WINE_BIN_DIR="$app/Contents/Resources/wine/bin"
    WINE="$WINE_BIN_DIR/wine"
    WINESERVER="$WINE_BIN_DIR/wineserver"
    export WINE WINESERVER
    export PATH="$WINE_BIN_DIR:$PATH"
    return 0
}

require_wine() { select_wine || die "Wine isn't installed yet. Run: bash \"$KIT_DIR/altium-wine.sh\" setup"; }

wine_env() {  # wine_env WINEDEBUG_VALUE
    export WINEPREFIX="$PREFIX"
    export WINEDEBUG="${1:--all}"
    local ov="winemenubuilder.exe=d"
    [ -n "$EXTRA_DLLOVERRIDES" ] && ov="$ov;$EXTRA_DLLOVERRIDES"
    export WINEDLLOVERRIDES="$ov"
    if [ "$DWM_COMPOSITION_OFF" = "1" ]; then
        export WINE_DWM_COMPOSITION=0
    else
        unset WINE_DWM_COMPOSITION
    fi
}

known_sha256() {
    case "$1" in
        wine-staging-11.16-osx64.tar.xz) echo "cd68f230c773a761b8a0423a08c51fbe49e89b6e52246f3866898d259a4988c6" ;;
        wine-devel-11.16-osx64.tar.xz)   echo "6f9af818b7af6001aeed7818cb32bf0155598c5ea4e3b33380a03cf814e033cd" ;;
        *) echo "" ;;
    esac
}

resolve_latest_wine() {
    local url
    url="$(curl -fsSIL -o /dev/null -w '%{url_effective}' "$GCENX_REPO/releases/latest" 2>/dev/null)"
    case "$url" in
        */tag/*) echo "${url##*/tag/}" ;;
        *) echo "" ;;
    esac
}

download_wine_version() {  # download_wine_version VERSION -> 0 on success, extracts into $WINE_ROOT
    local ver="$1"
    local asset="wine-${WINE_FLAVOR}-${ver}-osx64.tar.xz"
    local url="$GCENX_REPO/releases/download/${ver}/${asset}"
    local tarball="$DL_DIR/$asset"

    if [ ! -s "$tarball" ]; then
        say "Downloading $asset (~185 MB)"
        curl -fL --progress-bar -o "$tarball.part" "$url" || { rm -f "$tarball.part"; warn "Download failed: $url"; return 1; }
        mv "$tarball.part" "$tarball"
    fi

    local want got
    want="$(known_sha256 "$asset")"
    got="$(sha256_of "$tarball")"
    echo "    sha256 $asset = $got"
    if [ -n "$want" ] && [ "$want" != "$got" ]; then
        rm -f "$tarball"
        warn "Checksum mismatch for $asset (expected $want, got $got). Deleted it."
        return 1
    fi

    say "Extracting Wine $WINE_FLAVOR $ver"
    local tmp="$WORK_ROOT/.extract-$TS"
    rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xJf "$tarball" -C "$tmp" || { rm -rf "$tmp"; warn "Extraction failed."; return 1; }
    local app
    app="$(find_wine_app "$tmp")" || { rm -rf "$tmp"; warn "No Wine*.app inside $asset"; return 1; }
    rm -rf "$WINE_ROOT"; mkdir -p "$WINE_ROOT"
    mv "$app" "$WINE_ROOT/"
    rm -rf "$tmp"
    xattr -dr com.apple.quarantine "$WINE_ROOT" 2>/dev/null || true
    echo "$WINE_FLAVOR $ver" > "$WINE_ROOT/VERSION"
    return 0
}

ensure_wine() {  # ensure_wine [force]
    if [ "${1:-}" != "force" ] && find_wine_app "$WINE_ROOT" >/dev/null; then
        say "Using existing Wine: $(cat "$WINE_ROOT/VERSION" 2>/dev/null || echo unknown)"
        return 0
    fi
    local ver="$WINE_VERSION"
    if [ "$ver" = "latest" ]; then
        ver="$(resolve_latest_wine)"
        [ -n "$ver" ] || { warn "Couldn't resolve latest Gcenx release; using $PINNED_WINE_VERSION"; ver="$PINNED_WINE_VERSION"; }
    fi
    if ! download_wine_version "$ver"; then
        [ "$ver" = "$PINNED_WINE_VERSION" ] && die "Couldn't get Wine $ver."
        warn "Falling back to pinned Wine $PINNED_WINE_VERSION"
        download_wine_version "$PINNED_WINE_VERSION" || die "Couldn't get Wine $PINNED_WINE_VERSION either."
    fi
}

ensure_patched_wine() {  # build (or fetch) the patched bundle if USE_PATCHED_WINE=1 and it's missing
    [ "$USE_PATCHED_WINE" = "1" ] || return 0
    find_wine_app "$PATCHED_ROOT" >/dev/null && return 0
    # PATCHED_MODULES_DIR: prebuilt winemac.so/d2d1.dll/winhttp.dll (+ SHA256SUMS), skips the build
    say "No patched Wine yet; running build-patched-wine.sh"
    bash "$KIT_DIR/build-patched-wine.sh" ${PATCHED_MODULES_DIR:+--modules "$PATCHED_MODULES_DIR"} \
        || die "build-patched-wine.sh failed; see logs/LATEST-summary.txt"
}

# Altium (or its installer) running from this prefix? Only our own bundles' processes count,
# so a CrossOver bottle or another prefix doesn't block anything.
altium_running() {
    pgrep -f "$WORK_ROOT/wine" >/dev/null 2>&1 || return 1
    pgrep -f 'X2\.EXE|DXP\.EXE|Installer\.Exe|AltiumDesigner[0-9]*Setup' >/dev/null 2>&1
}

# ---- prefix ----------------------------------------------------------------
write_base_reg() {
    local f="$PREFIX/drive_c/altium-kit-base.reg"
    cat > "$f" <<'EOF'
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\WineDbg]
"ShowCrashDialog"=dword:00000000

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"winemenubuilder.exe"=""

[HKEY_CURRENT_USER\Control Panel\Desktop]
"FontSmoothing"="2"
"FontSmoothingType"=dword:00000002
"FontSmoothingGamma"=dword:00000578
"FontSmoothingOrientation"=dword:00000001
EOF
    echo 'C:\altium-kit-base.reg'
}

apply_registry() {  # imports base reg + optional wine-kit/extra.reg
    local log="$1"
    local winpath
    winpath="$(write_base_reg)"
    "$WINE" regedit /S "$winpath" >> "$log" 2>&1
    if [ -f "$KIT_DIR/extra.reg" ]; then
        cp "$KIT_DIR/extra.reg" "$PREFIX/drive_c/altium-kit-extra.reg"
        "$WINE" regedit /S 'C:\altium-kit-extra.reg' >> "$log" 2>&1
        say "Imported extra.reg"
    fi
}

# DXVK-macOS (zlib license, github.com/Gcenx/DXVK-macOS): D3D11 over Vulkan/MoltenVK. Altium's
# editors need D3D11 feature level 11, which Wine's own wined3d can't provide on macOS.
DXVK_TAG="v1.10.3-20230507-repack"
DXVK_ASSET="dxvk-macOS-async-v1.10.3-20230507-repack.tar.gz"
DXVK_SHA256="acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477"
DXVK_DIR="$DL_DIR/dxvk-macos/${DXVK_ASSET%.tar.gz}/x64"

ensure_dxvk() {
    [ -f "$DXVK_DIR/d3d11.dll" ] && [ -f "$DXVK_DIR/d3d10core.dll" ] && return 0
    local tarball="$DL_DIR/$DXVK_ASSET"
    if [ ! -s "$tarball" ]; then
        say "Downloading $DXVK_ASSET (~4 MB)"
        curl -fL --progress-bar -o "$tarball.part" "https://github.com/Gcenx/DXVK-macOS/releases/download/$DXVK_TAG/$DXVK_ASSET" \
            && mv "$tarball.part" "$tarball" || { rm -f "$tarball.part"; die "DXVK download failed."; }
    fi
    [ "$(sha256_of "$tarball")" = "$DXVK_SHA256" ] || { rm -f "$tarball"; die "DXVK checksum mismatch; deleted the download, try again."; }
    mkdir -p "$DL_DIR/dxvk-macos"
    tar -xzf "$tarball" -C "$DL_DIR/dxvk-macos" || die "DXVK extract failed."
    [ -f "$DXVK_DIR/d3d11.dll" ] || die "DXVK archive layout changed: no $DXVK_DIR/d3d11.dll"
}

install_dxvk() {  # copy d3d11/d3d10core next to X2.EXE (extra.reg limits the native override to X2.EXE)
    local ad="$1" f
    [ -f "$ad/X2.EXE" ] || return 0
    ensure_dxvk
    for f in d3d11.dll d3d10core.dll; do
        cmp -s "$DXVK_DIR/$f" "$ad/$f" && continue
        cp "$DXVK_DIR/$f" "$ad/$f" || die "Couldn't copy $f into $ad"
        say "Installed DXVK $f for Altium"
    done
}

cmd_setup() {
    check_platform
    local force=""
    [ "${1:-}" = "--force-wine" ] && force="force"
    ensure_wine "$force"
    ensure_patched_wine
    require_wine
    wine_env "-all"
    local log="$LOG_DIR/$TS-setup.log"
    say "Wine: $("$WINE" --version 2>&1)  ($WINE_APP)"

    if [ ! -f "$PREFIX/system.reg" ]; then
        # wineboot crashed creating a prefix under a ~160-character path (fine at ~20).
        [ ${#PREFIX} -le 80 ] || die "Prefix path is too long for Wine (${#PREFIX} chars): $PREFIX. Use a shorter ALTIUM_WINE_ROOT."
        say "Creating Wine prefix at $PREFIX (first run takes a minute or two)"
        WINEDEBUG="err+all" "$WINE" wineboot --init >> "$log" 2>&1
        "$WINESERVER" -w
        [ -f "$PREFIX/system.reg" ] || die "Prefix creation failed; see $log"
    else
        # Background services (e.g. Microsoft Edge's updater, installed with WebView2) keep the
        # prefix busy forever, so wineserver -w below would never return. Stop them first,
        # but never underneath a running Altium or installer.
        altium_running && die "Altium (or its installer) is running in this prefix. Close it, then run setup again."
        "$WINESERVER" -k 2>/dev/null; sleep 2
        say "Prefix exists; refreshing it for this Wine version"
        "$WINE" wineboot -u >> "$log" 2>&1
        "$WINESERVER" -w
    fi

    say "Setting Windows version: $WINDOWS_VERSION"
    "$WINE" winecfg -v "$WINDOWS_VERSION" >> "$log" 2>&1
    "$WINE" reg add 'HKCU\Software\Wine' /v Version /t REG_SZ /d "$WINDOWS_VERSION" /f >> "$log" 2>&1
    apply_registry "$log"
    "$WINESERVER" -w
    echo "$(cat "$WINE_ROOT/VERSION" 2>/dev/null) $WINDOWS_VERSION $(date)" > "$PREFIX/.altium-kit-setup"
    say "Setup done."
}

ensure_setup() {
    if ! select_wine || [ ! -f "$PREFIX/.altium-kit-setup" ]; then
        cmd_setup
    fi
    require_wine
}

# ---- winetricks ------------------------------------------------------------
ensure_winetricks() {
    if [ ! -x "$WINETRICKS" ] || [ -n "$(find "$WINETRICKS" -mtime +14 2>/dev/null)" ]; then
        say "Fetching winetricks"
        curl -fsSL -o "$WINETRICKS.part" "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks" \
            && mv "$WINETRICKS.part" "$WINETRICKS" && chmod +x "$WINETRICKS" \
            || { rm -f "$WINETRICKS.part"; [ -x "$WINETRICKS" ] || die "Couldn't download winetricks."; }
    fi
}

ensure_cabextract() {
    command -v cabextract >/dev/null 2>&1 && return 0
    local brew
    brew="$(find_brew)"
    if [ -n "$brew" ]; then
        say "Installing cabextract with Homebrew (winetricks needs it)"
        "$brew" install cabextract >> "$LOG_DIR/$TS-brew.log" 2>&1 || return 1
        export PATH="$(dirname "$brew"):$PATH"
        command -v cabextract >/dev/null 2>&1
        return $?
    fi
    return 1
}

cmd_deps() {
    ensure_setup
    local verbs="$*"
    [ -n "$verbs" ] || verbs="$WINETRICKS_VERBS"
    if [ -z "$verbs" ]; then
        say "No winetricks verbs configured."
        return 0
    fi
    ensure_winetricks
    if ! ensure_cabextract; then
        warn "cabextract not found and Homebrew isn't installed; skipping winetricks ($verbs)."
        warn "Install Homebrew (https://brew.sh) then: brew install cabextract"
        return 0
    fi
    wine_env "err+all"
    local log="$LOG_DIR/$TS-winetricks.log"
    say "winetricks: $verbs  (log: logs/$(basename "$log"))"
    # shellcheck disable=SC2086
    WINE="$WINE" WINESERVER="$WINESERVER" sh "$WINETRICKS" -q --unattended $verbs >> "$log" 2>&1
    local rc=$?
    "$WINESERVER" -w
    if [ $rc -eq 0 ]; then
        echo "$verbs" >> "$PREFIX/.altium-kit-deps"
        say "winetricks finished."
    else
        warn "winetricks exited with $rc; see $log"
    fi
    return $rc
}

# ---- logged launches -------------------------------------------------------
section() { printf '\n----- %s -----\n' "$1"; }

normalize() {  # strip +timestamp/+pid/+tid prefixes and volatile hex so identical lines dedupe
    # (GUIDs are left intact: the hex-run rule skips anything next to '-', '{' or '}')
    sed -E 's/^[0-9]+\.[0-9]+://; s/^[0-9a-f]{4,8}:[0-9a-f]{4,8}://; s/0x[0-9a-fA-F]+/0x_/g; s/(^|[^-{0-9a-fA-F])[0-9a-fA-F]{8,16}([^-}0-9a-fA-F]|$)/\1_\2/g'
}

summarize() {  # summarize LOG LABEL RC START_EPOCH
    local log="$1" label="$2" rc="$3" start="$4"
    local sum="${log%.log}.summary.txt"
    {
        echo "label:     $label"
        echo "exit code: $rc"
        echo "duration:  $(( $(date +%s) - start ))s"
        echo "wine:      $("$WINE" --version 2>/dev/null)  [$WINE_APP]"
        echo "macOS:     $(sw_vers -productVersion 2>/dev/null) ($(uname -m)), $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
        echo "WINEDEBUG: ${WINEDEBUG:-}"
        echo "overrides: ${WINEDLLOVERRIDES:-}   WINE_DWM_COMPOSITION=${WINE_DWM_COMPOSITION:-unset}"
        echo "log:       $(basename "$log")  ($(wc -l < "$log" | tr -d ' ') lines, $(du -h "$log" | cut -f1))"

        section "Crashes / unhandled exceptions / backtraces"
        grep -n -E -A30 'Unhandled exception|Unhandled page fault|Backtrace:|Assertion .* failed|wine: failed to start|err:seh:|err:virtual:' "$log" | head -250

        section "Exception codes seen (+seh)   [0eedfade=Delphi  e0434352=.NET  e06d7363=C++  c0000005=AV]"
        grep -o -E 'code=[0-9a-fA-F]{8}' "$log" | sort | uniq -c | sort -rn | head -20

        section "Processes started"
        grep -E 'CreateProcessInternalW|wine: failed to start|ShellExecute' "$log" | normalize | sed -E 's/^.*CreateProcessInternalW //' | head -80

        section "DLL load problems"
        grep -E 'err:module|not found|could not load|import_dll|Library .* which is needed' "$log" | normalize | sort | uniq -c | sort -rn | head -50

        section "Top err: lines"
        grep -E 'err:' "$log" | normalize | sort | uniq -c | sort -rn | head -60

        section "Top fixme: lines"
        grep -E 'fixme:' "$log" | normalize | sort | uniq -c | sort -rn | head -60

        section "Unimplemented functions"
        grep -E 'unimplemented function|Call from .* to unimplemented' "$log" | normalize | sort -u | head -40

        section "Native (non-Wine) DLLs loaded"
        grep -E 'trace:loaddll' "$log" | grep -E ': native' | sed -E 's/.*Loaded L"([^"]*)".*/\1/' | sort -u | head -200

        section "State after run"
        [ -f "$LOG_DIR/$TS-state.txt" ] && cat "$LOG_DIR/$TS-state.txt"

        section "Last 100 log lines"
        tail -n 100 "$log"
    } > "$sum" 2>&1
    cp "$sum" "$LOG_DIR/LATEST-summary.txt"
    say "Summary: logs/$(basename "$sum")  (also logs/LATEST-summary.txt)"
}

collect_app_logs() {  # copy log files written during the run (outside Program Files)
    local marker="$1" dest="$LOG_DIR/$TS-app-logs"
    local base="$PREFIX/drive_c"
    mkdir -p "$dest"
    find "$base/users" "$base/ProgramData" "$base/windows/temp" -type f -newer "$marker" \
        \( -iname '*.log' -o -iname '*.err' -o -iname '*install*.txt' -o -iname '*.dmp' \) -size -20M 2>/dev/null |
    while IFS= read -r f; do
        local rel="${f#"$base"/}"
        mkdir -p "$dest/$(dirname "$rel")"
        cp "$f" "$dest/$rel"
    done
    if [ -z "$(ls -A "$dest" 2>/dev/null)" ]; then rmdir "$dest"; else say "Copied app logs to logs/$(basename "$dest")"; fi
}

snapshot_state() {
    local out="$LOG_DIR/$TS-state.txt" pf="$PREFIX/drive_c/Program Files/Altium"
    {
        echo "== $pf"
        if [ -d "$pf" ]; then ls -la "$pf"; du -sh "$pf"/* 2>/dev/null; else echo "(missing)"; fi
        echo "== X2.EXE locations"
        find "$PREFIX/drive_c" -maxdepth 5 -iname 'X2.EXE' 2>/dev/null
        echo "== ProgramData/Altium"
        ls -la "$PREFIX/drive_c/ProgramData/Altium" 2>/dev/null || echo "(missing)"
        local key
        for key in 'HKLM\Software\Altium' 'HKLM\Software\WOW6432Node\Altium' 'HKCU\Software\Altium'; do
            echo "== reg query $key"
            WINEDEBUG=-all "$WINE" reg query "$key" /s 2>&1 | head -150
        done
    } > "$out" 2>&1
}

INTERRUPTED=0
launch_logged() {  # launch_logged LABEL WORKDIR EXE [ARGS...]
    local label="$1" workdir="$2"
    shift 2
    local log="$LOG_DIR/$TS-$label.log"
    local marker="$WORK_ROOT/.marker-$TS"
    touch "$marker"
    local start
    start="$(date +%s)"
    {
        echo "# $label  $(date)"
        echo "# cmd: wine $*"
        echo "# cwd: $workdir"
        echo "# WINEDEBUG=$WINEDEBUG  WINEDLLOVERRIDES=$WINEDLLOVERRIDES"
    } > "$log"
    say "Running: $* (log: logs/$(basename "$log"))"

    INTERRUPTED=0
    trap 'INTERRUPTED=1' INT
    ( cd "$workdir" && exec "$WINE" "$@" ) >> "$log" 2>&1 &
    local pid=$!
    local n=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 2
        n=$((n + 2))
        [ "$INTERRUPTED" = "1" ] && break
        if [ $((n % 30)) -eq 0 ]; then
            local last
            last="$(tail -n 3000 "$log" 2>/dev/null | grep -E 'err:|Unhandled' | tail -n 1 | normalize | cut -c1-150)"
            printf '   ... %ss elapsed, log %s%s\n' "$n" "$(du -h "$log" | cut -f1 | tr -d ' ')" "${last:+, last error: $last}"
        fi
    done
    local rc=0
    if [ "$INTERRUPTED" != "1" ]; then
        wait "$pid"; rc=$?
        say "Process exited with code $rc; waiting up to 15 min for child processes (Ctrl+C to stop)"
        "$WINESERVER" -w &
        local wpid=$! t=0
        while kill -0 "$wpid" 2>/dev/null && [ $t -lt 900 ] && [ "$INTERRUPTED" != "1" ]; do
            sleep 1; t=$((t + 1))
        done
        kill "$wpid" 2>/dev/null
    fi
    if [ "$INTERRUPTED" = "1" ]; then
        [ $rc -eq 0 ] && rc=130
        warn "Interrupted. Killing Wine processes in the prefix."
        "$WINESERVER" -k 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    trap - INT
    collect_app_logs "$marker"
    snapshot_state
    summarize "$log" "$label" "$rc" "$start"
    rm -f "$marker"
    return $rc
}

print_installer_tips() {
    cat <<'EOF'

  While the Altium installer runs:
   * License Agreement page -> click "Advanced Settings" -> untick "Unified Sign In".
     (Browser-based sign-in can't hand the result back to Wine; use the in-installer login.)
   * If the installer goes blurry/grey and stops responding, a dialog is probably behind it.
     Use Mission Control (F3 or swipe up) or the "Window" menu in the menu bar to bring it up.
   * If it's truly stuck: open a 2nd Terminal and run
         bash "<kit>/altium-wine.sh" hang-dump
     then come back here and press Ctrl+C.
   * Logs are summarized automatically when it exits.

EOF
}

cmd_install() {  # cmd_install [DIR | DIR/setup.exe]
    local dir="${1:-$ALTIUM_DIR}" exe=""
    case "$dir" in
        *.exe|*.Exe|*.EXE) exe="$(basename "$dir")"; dir="$(dirname "$dir")" ;;
    esac
    if [ -z "$exe" ]; then
        # Installer.Exe (Altium 18 and later) or AltiumDesigner<N>Setup.exe (older offline setups)
        exe="$(cd "$dir" 2>/dev/null && ls Installer.Exe AltiumDesigner*Setup.exe 2>/dev/null | head -n 1)"
    fi
    [ -n "$exe" ] && [ -f "$dir/$exe" ] || die "No Altium installer in $dir (pass the unzipped Altium offline setup folder)"
    ensure_setup
    wine_env "$WINEDEBUG_INSTALL"
    print_installer_tips | sed "s#<kit>#$KIT_DIR#"
    launch_logged installer "$dir" "$exe"
}

# The installed Altium: the newest X2.EXE (Altium 18 and later, 64-bit, Program Files), else
# DXP.EXE (Altium 17 and older, 32-bit, Program Files (x86)).
find_altium_exe() {
    local c="$PREFIX/drive_c" exe
    exe="$(find "$c/Program Files/Altium" -maxdepth 2 -iname 'X2.EXE' 2>/dev/null | sort | tail -n 1)"
    [ -n "$exe" ] || exe="$(find "$c/Program Files (x86)/Altium" "$c/Program Files/Altium" -maxdepth 2 \
        -iname 'DXP.EXE' 2>/dev/null | sort | tail -n 1)"
    echo "$exe"
}

cmd_run() {
    ensure_setup
    local exe
    exe="$(find_altium_exe)"
    [ -n "$exe" ] || die "No Altium (X2.EXE or DXP.EXE) under C:\\Program Files yet. Install first."
    install_dxvk "$(dirname "$exe")"
    case "$exe" in *DXP.EXE|*dxp.exe)
        grep -qw dotnet48 "$PREFIX/.altium-kit-deps" 2>/dev/null \
            || warn "Altium 17's .NET extensions need .NET 4.8: bash \"$KIT_DIR/altium-wine.sh\" deps dotnet48" ;;
    esac
    wine_env "$WINEDEBUG_RUN"
    # Only Altium 18+ (X2.EXE) has the WebView2 browser the watchdog ends.
    case "$exe" in *X2.EXE|*x2.exe) [ "${KILL_WEBVIEW2:-1}" = "1" ] && webview2_watchdog & ;; esac
    # Match the sRGB GDI surfaces on both versions, including AD26's UI around its GPU canvas.
    case "$exe" in
        *X2.EXE|*x2.exe) export ALTIUM_MAC_SRGB="${AD26_SRGB_WINDOWS:-1}" ;;
        *DXP.EXE|*dxp.exe) export ALTIUM_MAC_SRGB="${AD17_SRGB_WINDOWS:-1}" ;;
    esac
    # AD17's CefSharp GPU process spins under Wine. Software Chromium rendering
    # restores the Home page/reports without changing the PCB's Direct3D renderer.
    case "$exe" in *DXP.EXE|*dxp.exe)
        export ALTIUM_D3D9_UPLOADS="${AD17_FAST_UPLOADS:-1}"
        export ALTIUM_D3D9_UPLOAD_HINTS="${AD17_FAST_UPLOAD_HINTS:-1}"
        export ALTIUM_D3D9_QUEUED_UP="${AD17_FAST_UP_DRAWS:-1}"
        export ALTIUM_PARALLEL_GDI="${AD17_PARALLEL_GDI:-1}"
        export ALTIUM_GDI_WORKERS="${AD17_GDI_WORKERS:-2}"
        export ALTIUM_NATIVE_GDI="${AD17_NATIVE_GDI:-1}"
        export ALTIUM_NATIVE_GDI_WORKERS="${AD17_NATIVE_GDI_WORKERS:-2}"
        export ALTIUM_SMOOTH_SCHEMATIC_PAN="${AD17_SMOOTH_SCHEMATIC_PAN:-1}"
        if [ "${AD17_CEF_SOFTWARE_RENDERING:-1}" = "1" ]; then
            set -- --disable-gpu --disable-gpu-compositing "$@"
        fi ;;
    esac
    launch_logged altium "$(dirname "$exe")" "$(basename "$exe")" "$@"
}

etime_seconds() {  # etime_seconds PID -> seconds the process has been running
    ps -o etime= -p "$1" 2>/dev/null | awk -F'[-:]' '{n=NF; s=$n+60*$(n-1); if(n>2)s+=3600*$(n-2); if(n>3)s+=86400*$(n-3); print s}'
}

# Altium's Microsoft Edge WebView2 browser (it only drives the Home Page, which renders blank
# under Wine) has a thread whose message loop spins forever under Wine and floods wineserver,
# which more than halves Altium's frame rate (PCB pan measured at ~50 fps with it, ~130 fps
# without). Ending it after Altium has finished starting causes no errors; blocking it from
# starting does (Altium shows "File not found"). KILL_WEBVIEW2=0 turns this off.
webview2_watchdog() {
    sleep 20
    while pgrep -f 'X2.EXE' >/dev/null 2>&1; do
        local pid
        for pid in $(pgrep -f 'msedgewebview2.exe --embedded-browser-webview.*--webview-exe-name=X2.EXE'); do
            if [ "$(etime_seconds "$pid")" -ge 20 ] 2>/dev/null; then
                kill "$pid" 2>/dev/null && echo "$(date +%H:%M:%S) webview2 watchdog: ended Altium's WebView2 browser (pid $pid)"
            fi
        done
        sleep 10
    done
}

cmd_hang_dump() {
    require_wine
    wine_env "-all"
    local out="$LOG_DIR/$TS-hangdump.txt"
    say "Collecting backtraces of all Wine processes (can take a minute)"
    {
        echo "# hang-dump $(date)"
        section "info process"
        "$WINE" winedbg --command "info process" 2>&1
        section "bt all"
        "$WINE" winedbg --command "bt all" 2>&1
    } > "$out"
    cp "$out" "$LOG_DIR/LATEST-hangdump.txt"
    say "Wrote logs/$(basename "$out")"
}

cmd_doctor() {
    local out="$LOG_DIR/$TS-doctor.txt"
    {
        section "system"
        sw_vers 2>&1; uname -a
        sysctl -n machdep.cpu.brand_string hw.memsize hw.optional.arm64 2>&1
        echo "rosetta: $(arch -x86_64 /usr/bin/true 2>/dev/null && echo yes || echo no)"
        df -h "$HOME" 2>&1
        echo "brew: $(find_brew || echo none)"
        echo "cabextract: $(command -v cabextract || echo none)"
        section "kit"
        echo "KIT_DIR=$KIT_DIR"; echo "ALTIUM_DIR=$ALTIUM_DIR"; echo "WORK_ROOT=$WORK_ROOT"
        ls -la "$ALTIUM_DIR" 2>&1 | head -30
        section "config.sh"
        cat "$KIT_DIR/config.sh" 2>&1
        section "wine"
        if select_wine; then
            echo "app: $WINE_APP"; cat "$WINE_ROOT/VERSION" 2>/dev/null
            "$WINE" --version 2>&1
            ls "$WINE_APP/Contents/Resources/wine/lib/wine" 2>&1
        else
            echo "not installed"
        fi
        section "prefix"
        ls -la "$PREFIX" 2>&1
        cat "$PREFIX/.altium-kit-setup" "$PREFIX/.altium-kit-deps" 2>/dev/null
        grep -A3 -i '"ProductName"' "$PREFIX/system.reg" 2>/dev/null | head -8
        ls -la "$PREFIX/drive_c/Program Files/Altium" 2>&1
        section "patched builds"
        ls -la "$PATCHED_ROOT" 2>&1
        cat "$PATCHED_ROOT/PATCHES" 2>/dev/null
    } > "$out" 2>&1
    say "Wrote logs/$(basename "$out")"
}

cmd_wine() {
    require_wine
    wine_env "${WINEDEBUG_USER:-err+all}"
    [ $# -gt 0 ] || die "Usage: altium-wine.sh wine <program> [args]   e.g. wine winecfg"
    "$WINE" "$@"
}

cmd_reset() {
    case "$PREFIX" in */AltiumWine/prefix) ;; *) die "Refusing to delete unexpected path: $PREFIX" ;; esac
    [ -d "$PREFIX" ] || { say "No prefix at $PREFIX"; return 0; }
    if ask_yes "Delete the Wine prefix $PREFIX (Altium install inside it goes too)?"; then
        select_wine && WINEPREFIX="$PREFIX" "$WINESERVER" -k 2>/dev/null
        rm -rf "$PREFIX"
        say "Prefix deleted."
    fi
}

LAUNCHER_NAME="Altium Designer (Wine).app"

cmd_launcher() {  # cmd_launcher [DIR]: a small .app that runs `altium-wine.sh run`, with Altium's icon
    local dir="${1:-$HOME/Applications}" app exe exe_name name="$LAUNCHER_NAME"
    exe="$(find_altium_exe)"
    [ -n "$exe" ] || die "Altium isn't installed in $PREFIX yet; install it first."
    exe_name="$(basename "$exe")"
    # Altium 17 and older (DXP.EXE) get their own name, e.g. "Altium Designer 17 (Wine).app".
    case "$exe_name" in DXP.EXE|dxp.exe)
        name="Altium Designer $(basename "$(dirname "$exe")" | sed 's/^AD//') (Wine).app" ;;
    esac
    app="$dir/$name"
    mkdir -p "$dir" || die "Can't create $dir"

    # macOS won't let an app read ~/Downloads, ~/Desktop or ~/Documents (it fails with
    # "Operation not permitted", without a prompt), so the launcher runs a copy of such a kit.
    local kit="$KIT_DIR"
    case "$KIT_DIR/" in
        "$HOME/Downloads/"*|"$HOME/Desktop/"*|"$HOME/Documents/"*)
            kit="$WORK_ROOT/kit"
            mkdir -p "$kit/logs"
            rsync -a --delete --exclude logs/ --exclude dist/ --exclude config.local.sh \
                --exclude .git/ --exclude .github/ --exclude __pycache__/ "$KIT_DIR/" "$kit/" \
                || die "Couldn't copy the kit to $kit"
            say "macOS blocks apps from reading $(dirname "$KIT_DIR"), so the launcher uses a copy of the kit:"
            say "  $kit  (run \"altium-wine.sh launcher\" again after changing the kit here)"
            ;;
    esac
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

    local icon_key=""
    # The icon is optional; python3 only works once the Xcode Command Line Tools are installed.
    if xcode-select -p >/dev/null 2>&1; then
        local tmp png
        tmp="$(mktemp -d)"
        if png="$(python3 "$KIT_DIR/tools/exe-icon.py" "$exe" "$tmp/icon" 2>/dev/null)" &&
           sips -s format icns "$png" --out "$app/Contents/Resources/AppIcon.icns" >/dev/null 2>&1; then
            icon_key="<key>CFBundleIconFile</key><string>AppIcon</string>"
        fi
        rm -rf "$tmp"
    fi

    cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${name%.app}</string>
    <key>CFBundleIdentifier</key><string>local.altium-wine.launcher.$(echo "$WORK_ROOT" | shasum | cut -c1-8)</string>
    <key>CFBundleExecutable</key><string>altium-wine-launcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    $icon_key
    <!-- Wine shows its own Dock icon for Altium; the launcher itself stays out of the Dock. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
    {
        echo '#!/bin/bash'
        echo "# Generated by altium-wine.sh launcher on $(date)."
        printf 'export ALTIUM_WINE_ROOT=%q\n' "$WORK_ROOT"
        printf 'KIT=%q\n' "$kit"
        printf 'EXE=%q\n' "$exe_name"
        cat <<'EOF'
if pgrep -f "$ALTIUM_WINE_ROOT/wine" >/dev/null 2>&1 && pgrep -f "$EXE" >/dev/null 2>&1; then
    osascript -e 'display notification "Altium Designer is already running." with title "Altium Designer (Wine)"'
    exit 0
fi
if [ ! -f "$KIT/altium-wine.sh" ]; then
    osascript -e "display alert \"Altium Designer (Wine)\" message \"The kit is missing: $KIT\""
    exit 1
fi
exec /bin/bash "$KIT/altium-wine.sh" run </dev/null >/dev/null 2>&1
EOF
    } > "$app/Contents/MacOS/altium-wine-launcher"
    chmod +x "$app/Contents/MacOS/altium-wine-launcher"
    touch "$app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app" 2>/dev/null || true
    say "Created $app${icon_key:+ (with the Altium icon)}"
}

cmd_uninstall() {
    local yes=0
    [ "${1:-}" = "--yes" ] && yes=1
    # Only delete a directory that is recognizably ours.
    case "$WORK_ROOT" in ""|/|"$HOME"|"$HOME/") die "Refusing to delete WORK_ROOT=$WORK_ROOT" ;; esac
    [ -d "$WORK_ROOT/prefix" ] || [ -d "$WORK_ROOT/wine" ] || [ -d "$WORK_ROOT/wine-patched" ] \
        || die "$WORK_ROOT doesn't look like an Altium-on-Wine install (no prefix/ or wine/); not deleting it."
    warn "This deletes $WORK_ROOT ($(du -sh "$WORK_ROOT" 2>/dev/null | cut -f1)): Wine, the Altium install and"
    warn "everything stored inside the Windows prefix, including projects under"
    warn "  $PREFIX/drive_c/users/Public/Documents/Altium"
    warn "Push or copy any work you want to keep first. Your Altium offline installer download is not touched."
    if [ $yes != 1 ]; then
        local reply
        printf 'Type "delete" to continue: '
        read -r reply || reply=""
        [ "$reply" = "delete" ] || { say "Cancelled."; return 1; }
    fi
    altium_running && die "Altium is running. Close it first."
    if select_wine; then WINEPREFIX="$PREFIX" "$WINESERVER" -k 2>/dev/null; sleep 1; fi
    local app
    for app in "$HOME/Applications/Altium Designer"*"(Wine).app"; do  # only launchers for this root
        [ -f "$app/Contents/MacOS/altium-wine-launcher" ] || continue
        grep -qxF "export ALTIUM_WINE_ROOT=$(printf %q "$WORK_ROOT")" "$app/Contents/MacOS/altium-wine-launcher" || continue
        rm -rf "$app" && say "Removed $app"
    done
    rm -rf "$WORK_ROOT" && say "Removed $WORK_ROOT"
    case "$KIT_DIR" in "$WORK_ROOT"/*) ;; *) say "The kit itself is still at $KIT_DIR" ;; esac
}

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
    echo "# altium-wine.sh $*  ($(date); kit: $KIT_DIR)"
    local cmd="${1:-default}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        default)
            ensure_setup
            if [ -n "$WINETRICKS_VERBS" ] && ! grep -qxF "$WINETRICKS_VERBS" "$PREFIX/.altium-kit-deps" 2>/dev/null; then
                cmd_deps
            fi
            cmd_install "$@"
            ;;
        setup)      cmd_setup "$@" ;;
        deps)       cmd_deps "$@" ;;
        install)    cmd_install "$@" ;;
        run)        cmd_run "$@" ;;
        hang-dump)  cmd_hang_dump ;;
        doctor)     cmd_doctor ;;
        wine)       cmd_wine "$@" ;;
        launcher)   cmd_launcher "$@" ;;
        reset)      cmd_reset ;;
        uninstall)  cmd_uninstall "$@" ;;
        help|-h|--help) usage ;;
        *) usage; die "Unknown command: $cmd" ;;
    esac
}

main "$@"
