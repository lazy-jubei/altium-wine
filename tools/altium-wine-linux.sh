#!/bin/bash
# Linux entry point, called by the kit's install.sh and altium-wine.sh.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$KIT_DIR/tools/altium-prefix.sh"

die() { printf 'Altium Wine: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'HELP'
Altium Designer on Linux (x86-64)

  bash install.sh --altium-installer PATH [--root DIR] [--no-launcher]
  bash install.sh --skip-altium [--root DIR]
  bash build-patched-wine.sh   Build the Linux Wine networking and drawing modules
  bash altium-wine.sh setup
  bash altium-wine.sh update [--check] [--root DIR] [--no-launcher]
  bash altium-wine.sh install PATH
  bash altium-wine.sh run [FILE ...]
  bash altium-wine.sh launcher
  bash altium-wine.sh doctor
  bash altium-wine.sh wine PROGRAM [ARG ...]

PATH can be an online setup executable, an offline ZIP, or an extracted setup folder.
ALTIUM_WINE_ROOT defaults to ~/AltiumWineLinux.
ALTIUM_WINE_BIN selects another Wine executable. Use a separate root to test it.
ALTIUM_WINE_RENDERER selects wined3d (default), wined3d-vulkan, or patched dxvk for X2.EXE.
ALTIUM_WINE_NVIDIA=1 enables NVIDIA PRIME offload for WineD3D with OpenGL.
ALTIUM_WINE_INSTALL_DESKTOP defaults to native; use 1280x800 for a Wine desktop.
ALTIUM_WINE_DESKTOP sets a virtual desktop for the editor, e.g. 1280x800.
HELP
}

WINE_TAG=11.22
WINE_PACKAGE="wine-$WINE_TAG-staging-amd64-wow64"
WINE_SHA256=eafe530ccdc188ffb00ee8dae962f16b29ff0602953b73b23c9ad3394286381a
LLVM_TAG=20261117
LLVM_PACKAGE="llvm-mingw-$LLVM_TAG-ucrt-ubuntu-22.04-x86_64"
LLVM_SHA256=e7a15a49a2ea95e9f3d8a9d0cfabe5052a4b10fb4777cc54de5a8c27b64bb701
WINE_SOURCE_REV=9f8c4ae4d35c7ff4153267aba9618c026f5f5583
RELEASES_URL=https://github.com/lazy-jubei/altium-wine/releases
# Wine module, PE architecture, prefix directory, output filename.
WINE_PATCH_MODULES=(
    'winhttp x86_64 system32 winhttp.dll'
    'd2d1 x86_64 system32 d2d1.dll'
    'dwrite x86_64 system32 dwrite.dll'
    'gdiplus x86_64 system32 gdiplus.dll'
    'gdiplus i386 syswow64 gdiplus-i386.dll'
)

set_paths() {
    ROOT="$(realpath -m -- "${1:-${ALTIUM_WINE_ROOT:-$HOME/AltiumWineLinux}}")"
    PREFIX="$ROOT/prefix"
    DOWNLOADS="$ROOT/downloads"
    LOGS="$ROOT/logs"
    WINE="${ALTIUM_WINE_BIN:-$ROOT/runners/$WINE_PACKAGE/bin/wine}"
    if [[ -n ${ALTIUM_WINE_BIN:-} ]]; then
        WINE="$(command -v -- "$WINE")" || die "Wine executable unavailable: $ALTIUM_WINE_BIN"
        WINE="$(realpath -- "$WINE")"
    fi
    export WINEPREFIX="$PREFIX" WINEDEBUG="${ALTIUM_WINEDEBUG:-${WINEDEBUG:-fixme-all}}"
}

sha_matches() {
    printf '%s  %s\n' "$1" "$2" | sha256sum --check --status
}

download() (
    local url="$1" archive="$2" checksum="$3" temporary
    if [[ -f $archive ]] && sha_matches "$checksum" "$archive"; then
        return
    fi
    temporary="$(mktemp -- "$archive.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    printf 'Downloading %s\n' "${archive##*/}" >&2
    curl --proto '=https' --proto-redir '=https' -fLsS --retry 2 -o "$temporary" "$url"
    sha_matches "$checksum" "$temporary" || die "Checksum mismatch for ${archive##*/}"
    mv -T -- "$temporary" "$archive"
)

unpack_release() (
    local url="$1" archive="$2" checksum="$3" directory="$4" expected="$5" stage
    [[ -s "$directory/$expected" ]] && return
    mkdir -p -- "$(dirname "$directory")" "$DOWNLOADS"
    exec 9>"$DOWNLOADS/.release.lock"
    flock 9
    [[ -s "$directory/$expected" ]] && return
    download "$url" "$archive" "$checksum" || exit 1
    stage="$(mktemp -d -- "$(dirname "$directory")/.unpack.XXXXXX")"
    trap 'rm -rf -- "$stage"' EXIT
    tar -xf "$archive" -C "$stage" || exit 1
    [[ -s "$stage/${directory##*/}/$expected" ]] || die "Unexpected layout in ${archive##*/}"
    mv -T -- "$stage/${directory##*/}" "$directory"
)

ensure_wine() {
    if [[ ! -x $WINE && -z ${ALTIUM_WINE_BIN:-} ]]; then
        unpack_release "https://github.com/Kron4ek/Wine-Builds/releases/download/$WINE_TAG/$WINE_PACKAGE.tar.xz" \
            "$DOWNLOADS/$WINE_PACKAGE.tar.xz" "$WINE_SHA256" "$ROOT/runners/$WINE_PACKAGE" bin/wine || exit 1
    fi
    [[ -x $WINE ]] || die "Wine executable unavailable: $WINE"
}

get_mingw() {
    local compiler="$ROOT/build/$LLVM_PACKAGE/bin/x86_64-w64-mingw32-clang"
    if [[ ${1:-} != wow64 ]] || command -v i686-w64-mingw32-gcc >/dev/null; then
        if command -v x86_64-w64-mingw32-gcc; then return; fi
    fi
    unpack_release "https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_TAG/$LLVM_PACKAGE.tar.xz" \
        "$DOWNLOADS/$LLVM_PACKAGE.tar.xz" "$LLVM_SHA256" "$ROOT/build/$LLVM_PACKAGE" bin/x86_64-w64-mingw32-clang || return 1
    printf '%s\n' "$compiler"
}

replace_file() (
    local source="$1" destination="$2" stage
    if cmp -s "$source" "$destination"; then return; fi
    stage="$(mktemp -- "$destination.XXXXXX")"
    trap 'rm -f -- "$stage"' EXIT
    install -m 644 "$source" "$stage"
    mv -T -- "$stage" "$destination"
)

patch_user32() (
    [[ $WINE = "$ROOT/runners/$WINE_PACKAGE/bin/wine" ]] || return 0
    local patch="$KIT_DIR/patches/pe-add-stub-exports.py"
    local dll="$ROOT/runners/$WINE_PACKAGE/lib/wine/x86_64-windows/user32.dll"
    local installed="$PREFIX/drive_c/windows/system32/user32.dll" stage
    if ! python3 "$patch" --has-export "$dll" InheritWindowMonitor; then
        stage="$(mktemp -- "$dll.XXXXXX")"
        trap 'rm -f -- "$stage"' EXIT
        python3 "$patch" "$dll" "$stage" InheritWindowMonitor=1 >&2 || exit 1
        chmod --reference="$dll" "$stage"
        mv -T -- "$stage" "$dll"
    fi
    # Existing prefixes already have a copy of the old builtin.
    if [[ -f $installed ]]; then replace_file "$dll" "$installed"; fi
)

apply_built_modules() {
    [[ $WINE = "$ROOT/runners/$WINE_PACKAGE/bin/wine" ]] || return 0
    local spec name arch system_dir artifact module dll installed
    for spec in "${WINE_PATCH_MODULES[@]}"; do
        read -r name arch system_dir artifact <<< "$spec"
        module="$ROOT/build/wine-linux-output/$artifact"
        if [[ ! -s $module && $name = gdiplus ]]; then
            module="$KIT_DIR/modules/linux-gdiplus/$WINE_SOURCE_REV/$artifact"
        fi
        [[ -s $module ]] || continue
        dll="$ROOT/runners/$WINE_PACKAGE/lib/wine/$arch-windows/$name.dll"
        installed="$PREFIX/drive_c/windows/$system_dir/$name.dll"
        replace_file "$module" "$dll"
        if [[ -f $installed ]]; then replace_file "$module" "$installed"; fi
    done
}

build_wine_modules() (
    if [[ ${1:-} == --help ]]; then
        printf '%s\n' 'Build the shared WinHTTP, Direct2D, DirectWrite and GDI+ fixes for the pinned Linux Wine build.' \
            'Requires Git, GCC, make, bison, flex and m4. The kit supplies MinGW if needed.'
        return
    fi
    [[ $# = 0 ]] || die 'On Linux, build-patched-wine.sh accepts --help or no options.'
    local source="$ROOT/build/wine-linux-source" build="$ROOT/build/wine-linux-build-wow64"
    local output="$ROOT/build/wine-linux-output" lock="$ROOT/build/wine-linux-build/.build.lock"
    local patch spec name arch artifact index
    local tool compiler log targets=()
    local patches=(0004-winhttp-infinite-receive-timeout.patch
                   0003-d2d1-fast-redraw.patch 0037-d2d1-ordered-solid-batch.patch
                   0038-d2d1-text-aa-scaled.patch 0042-dwrite-cache-scaled-glyphs.patch
                   0031-gdiplus-staging-sync.patch 0057-gdiplus-windows-cell-metrics.patch)
    for tool in git gcc make bison flex m4; do
        command -v "$tool" >/dev/null || die "Missing Wine build tool: $tool"
    done
    compiler="$(get_mingw wow64)" || exit 1
    PATH="$(dirname "$compiler"):$PATH"
    export PATH
    # Older 64-bit-only builds use the same source and output directories.
    mkdir -p "$build" "$output" "$LOGS" "$(dirname "$lock")"
    exec 5>"$lock"
    flock 5
    log="$(mktemp --suffix=.log "$LOGS/build-wine.XXXXXX")"
    printf 'Building patched Wine modules (log %s)\n' "$log"
    {
        if [[ ! -d "$source/.git" ]]; then
            git clone --depth 1 --branch "wine-$WINE_TAG" https://github.com/wine-mirror/wine.git "$source" || exit 1
        fi
        [[ $(git -C "$source" rev-parse HEAD) = "$WINE_SOURCE_REV" ]] || die "Unexpected Wine checkout in $source"
        # Compose the patch stack against the pinned source before touching the
        # working tree. Some Direct2D patches modify lines in an earlier patch.
        index="$(mktemp -- "$build/.index.XXXXXX")"
        trap 'rm -f -- "$index"' EXIT
        (
            export GIT_INDEX_FILE="$index"
            git -C "$source" read-tree "$WINE_SOURCE_REV"
            for patch in "${patches[@]}"; do
                git -C "$source" apply --cached "$KIT_DIR/patches/$patch" || exit 1
            done
            while IFS= read -r -d '' name; do
                if ! git -C "$source" diff --quiet -- "$name"; then
                    git -C "$source" checkout-index --force -- "$name" || exit 1
                fi
            done < <(git -C "$source" diff --cached --name-only -z "$WINE_SOURCE_REV")
        ) || exit 1
        cd "$build" || exit 1
        if [[ ! -f Makefile ]]; then
            "$source/configure" --enable-archs=i386,x86_64 --disable-tests --without-x --without-wayland \
                --without-freetype --without-alsa --without-pulse || exit 1
        fi
        for spec in "${WINE_PATCH_MODULES[@]}"; do
            read -r name arch _ artifact <<< "$spec"
            targets+=("dlls/$name/$arch-windows/$name.dll")
        done
        make -j "${ALTIUM_WINE_BUILD_JOBS:-$(nproc)}" "${targets[@]}" || exit 1
        for spec in "${WINE_PATCH_MODULES[@]}"; do
            read -r name arch _ artifact <<< "$spec"
            replace_file "$build/dlls/$name/$arch-windows/$name.dll" "$output/$artifact"
        done
    } >>"$log" 2>&1
    printf 'Built Wine modules in %s. Restart Designer to load them.\n' "$output"
)

prefix_prepared() {
    [[ -f "$PREFIX/.altium-linux-setup" && -f "$PREFIX/drive_c/windows/system32/kernel32.dll" ]]
}

setup() (
    ensure_wine
    mkdir -p -- "$LOGS"
    exec 8>"$ROOT/.setup.lock"
    flock 8
    # wineserver can outlive setup. It must not inherit and retain this lock.
    patch_user32
    apply_built_modules
    # wineserver may still have its registry buffered when setup finishes.
    # Reconfiguring that live prefix can wait on its previous display session.
    prefix_prepared && return
    local log
    log="$(mktemp --suffix=.log "$LOGS/setup.XXXXXX")"
    printf 'Preparing %s (log %s)\n' "$PREFIX" "$log"
    if [[ ! -f "$PREFIX/drive_c/windows/system32/kernel32.dll" ]]; then
        WINEDLLOVERRIDES="mscoree,mshtml=d${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}" \
            "$WINE" wineboot --init 8>&- >>"$log" 2>&1 || die "wineboot failed. See $log"
    fi
    {
        "$WINE" winecfg -v win10 8>&- &&
        "$WINE" reg add 'HKCU\Software\Microsoft\Avalon.Graphics' /v DisableHWAcceleration /t REG_DWORD /d 1 /f 8>&-
    } >>"$log" 2>&1 || die "Wine configuration failed. See $log"
    touch "$PREFIX/.altium-linux-setup"
)

find_setup_exe() {
    local directory="$1" installers=()
    mapfile -d '' -t installers < <(find "$directory" -maxdepth 3 -type f \
        \( -iname 'Installer.exe' -o -iname 'AltiumDesigner*Setup.exe' \
           -o -iname 'AltiumDesigner*Setup_*.exe' \) -print0)
    case ${#installers[@]} in
        0) die "No Altium setup executable found in $directory" ;;
        1) printf '%s\n' "${installers[0]}" ;;
        *) die "Multiple setup executables found in $directory. Pass the desired executable." ;;
    esac
}

installer_exe() (
    local source digest destination stage
    [[ $# = 1 ]] || die 'Pass an online setup executable, offline ZIP, or setup folder.'
    source="$(realpath -e -- "$1")" || die "Installer path unavailable: $1"
    if [[ -d $source ]]; then
        find_setup_exe "$source"
    elif [[ ${source,,} == *.zip && -f $source ]]; then
        digest="$(sha256sum < "$source")"
        destination="$DOWNLOADS/offline-${digest%% *}"
        if [[ ! -d $destination ]]; then
            stage="$(mktemp -d -- "$DOWNLOADS/.offline.XXXXXX")"
            trap 'rm -rf -- "$stage"' EXIT
            printf 'Extracting %s\n' "$source" >&2
            unzip -q -o "$source" -d "$stage" || die "Could not extract $source"
            find_setup_exe "$stage" >/dev/null || exit 1
            mv -T -- "$stage" "$destination"
        fi
        find_setup_exe "$destination"
    elif [[ ${source,,} == *.exe && -f $source ]]; then
        printf '%s\n' "$source"
    else
        die "Unsupported installer path: $source"
    fi
)

launch() {
    local label="$1" desktop="$2" exe="$3" log windows_exe helper
    shift 3
    local command=("$WINE" "$exe" "$@")
    if [[ $label = Setup || $desktop != native ]]; then
        windows_exe="$("$WINE" winepath -w "$exe")" || die "Cannot translate $exe"
    fi
    if [[ $label = Setup ]]; then
        helper="$(build_helper)" || exit 1
        command=("$WINE" "$helper" --setup-native "$windows_exe" "$@")
    fi
    if [[ $desktop != native ]]; then
        [[ $desktop =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || die "Invalid Wine desktop size: $desktop"
        command=("$WINE" explorer "/desktop=Altium-$label,$desktop" "$windows_exe" "$@")
        if [[ $label = Setup ]]; then
            helper="$("$WINE" winepath -w "$helper")" || die 'Cannot translate the setup helper path.'
            command=("$WINE" explorer "/desktop=Altium-$label,$desktop" "$helper" --setup-desktop "$windows_exe" "$@")
        fi
    fi
    log="$(mktemp --suffix=.log "$LOGS/$label.XXXXXX")"
    printf 'Opening %s (log %s)\n' "$exe" "$log"
    (cd "$(dirname "$exe")" && "${command[@]}") >>"$log" 2>&1
}

install_altium() (
    mkdir -p -- "$DOWNLOADS"
    exec 7>"$ROOT/.install.lock"
    flock -n 7 || die "An installer is already running in $ROOT"
    local exe name options=()
    exe="$(installer_exe "$@")" || exit 1
    setup
    name="${exe##*/}"
    case "${name,,}" in
        altiumdesigner*setup.exe|altiumdesigner*setup_*.exe) options=(--online) ;;
    esac
    printf '%s\n' 'For online setup, leave Unified Sign In enabled to sign in through your browser.' \
        'For offline setup, disable Unified Sign In under Advanced Settings if it is enabled.'
    launch Setup "${ALTIUM_WINE_INSTALL_DESKTOP:-native}" "$exe" "${options[@]}"
)

get_altium() {
    if [[ -n ${ALTIUM_WINE_EXE:-} ]]; then
        [[ -f $ALTIUM_WINE_EXE ]] || return 1
        realpath -- "$ALTIUM_WINE_EXE"
    else
        find_altium_exe
    fi
}

seed_preference() {
    local key="$1" name="$2" value="$3"
    if ! "$WINE" reg query "$key" /v "$name" /reg:64 >/dev/null 2>&1; then
        # reg.exe without /f also protects a preference set by a concurrent process.
        "$WINE" reg add "$key" /v "$name" /t REG_SZ /d "$value" /reg:64 </dev/null >/dev/null 2>&1 ||
            printf 'Could not initialize %s in %s.\n' "$name" "$key" >&2
    fi
}

configure_ad26_defaults() {
    local preferences
    printf -v preferences 'HKCU\\Software\\Altium\\%s\\DesignExplorer\\Preferences' "$1"
    if [[ ${AD26_CEF_FALLBACK:-0} = 1 ]]; then
        seed_preference "$preferences"'\InternalOptions\System.UseWebView2' Value 0
    fi
    # The translucent Board Insight HUD can leave old pixels over the PCB canvas.
    seed_preference "$preferences"'\AdvPCB\HeadsUpDisplay' Display 0
}

build_helper() (
    local source="$KIT_DIR/tools/altium-browser-launch.c"
    local binary="$ROOT/build/browser-bridge/cmd.exe" compiler stage
    mkdir -p -- "$(dirname "$binary")"
    exec 6>"$(dirname "$binary")/.build.lock"
    flock 6
    if [[ ! -s $binary || $source -nt $binary || ! -f "$binary.built" ]]; then
        compiler="$(get_mingw)" || exit 1
        stage="$(mktemp -- "$binary.XXXXXX")"
        trap 'rm -f -- "$stage"' EXIT
        "$compiler" -O2 -s -municode -mwindows -o "$stage" "$source" -lshell32 || die 'Could not compile the browser bridge.'
        mv -T -- "$stage" "$binary"
        touch "$binary.built"
    fi
    printf '%s\n' "$binary"
)

prepare_browser_bridge() {
    local target="$1/cmd.exe" binary
    [[ -e $target && ! -L $target ]] && return 0
    binary="$(build_helper)" || return 1
    if [[ ! -e $target && ! -L $target ]]; then
        ln -sT -- "$binary" "$target" || [[ $(readlink -- "$target") = "$binary" ]] ||
            die "Could not install $target"
    fi
}

select_renderer() {
    local directory="$1" choice="$2" dll
    local dxvk="${ALTIUM_WINE_DXVK_DIR:-$ROOT/build/dxvk-linux/output}"
    case "$choice" in
        dxvk)
            dxvk="$(realpath -m -- "$dxvk")"
            for dll in dxgi.dll d3d11.dll d3d10core.dll; do
                [[ -s "$dxvk/$dll" ]] || die "Build patched DXVK with tools/build-linux-dxvk.sh first."
                if [[ -e "$directory/$dll" || -L "$directory/$dll" ]]; then
                    cmp -s "$dxvk/$dll" "$directory/$dll" || die "Different $dll in $directory. Use ALTIUM_WINE_RENDERER=wined3d."
                fi
            done
            for dll in dxgi.dll d3d11.dll d3d10core.dll; do
                [[ -e "$directory/$dll" ]] || ln -sT -- "$dxvk/$dll" "$directory/$dll" ||
                    cmp -s "$dxvk/$dll" "$directory/$dll" || die "Could not stage $dll"
            done
            export WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=n,b${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
            export DXVK_LOG_PATH="${DXVK_LOG_PATH:-$LOGS}"
            ;;
        wined3d|wined3d-vulkan)
            export WINEDLLOVERRIDES="dxgi,d3d11,d3d10core=b${WINEDLLOVERRIDES:+;$WINEDLLOVERRIDES}"
            local backend=opengl
            if [[ $choice = wined3d-vulkan ]]; then backend=vulkan; fi
            export WINE_D3D_CONFIG="renderer=$backend${WINE_D3D_CONFIG:+,$WINE_D3D_CONFIG}"
            if [[ $backend = opengl && ${ALTIUM_WINE_NVIDIA:-0} = 1 ]]; then
                export __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia
            fi
            ;;
        *) die "Unknown renderer: $choice (choose wined3d, wined3d-vulkan, or dxvk)" ;;
    esac
}

run_altium() {
    local exe arg profile
    local arguments=()
    if ! exe="$(get_altium)" || [[ -z $exe ]]; then
        die "Altium is missing in $PREFIX. Run install.sh first."
    fi
    setup
    if [[ ${exe,,} == */x2.exe ]]; then
        export WINE_D2D_TEXT_AA="${WINE_D2D_TEXT_AA:-1}"
        profile="$(find_ad26_profile "$exe")" || profile=""
        if [[ -n $profile ]]; then
            configure_ad26_defaults "$profile"
            prepare_browser_bridge "$(dirname "$exe")"
        fi
        if [[ ${AD26_CEF_SOFTWARE_RENDERING:-${AD26_CEF_FALLBACK:-0}} = 1 ]]; then
            arguments+=(--disable-gpu --disable-gpu-compositing --in-process-gpu)
        fi
        select_renderer "$(dirname "$exe")" "${ALTIUM_WINE_RENDERER:-wined3d}"
    fi
    for arg do
        if [[ -e $arg ]]; then
            arg="$("$WINE" winepath -w "$arg")" || die 'Could not translate the document path.'
        fi
        arguments+=("$arg")
    done
    launch Designer "${ALTIUM_WINE_DESKTOP:-native}" "$exe" "${arguments[@]}"
}

desktop_quote() {
    local value="$1"
    value=${value//\\/\\\\\\\\}
    value=${value//\"/\\\\\"}
    value=${value//\$/\\\\\$}
    value=${value//\`/\\\\\`}
    printf '"%s"' "${value//%/%%}"
}

desktop_startup_class() {
    local name="${1##*/}"
    [[ -n $name && $name != *[$'\r\n']* ]] || return 1
    # Wine's X11 driver uses the lowercase executable name for WM_CLASS.
    name="${name//\\/\\\\}"
    printf 'StartupWMClass=%s\n' "${name,,}"
}

release_kit() {
    local path
    path="$(realpath -e -- "$1")" || return 1
    [[ ${path%/*} = "$ROOT/kits" && ${path##*/} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ &&
        -s "$path/.release-sha256" && -f "$path/altium-wine.sh" ]] || return 1
    printf '%s\n' "$path"
}

version_is_newer() {
    [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n 1) = "$1" ]]
}

has_update_prefix() {
    prefix_prepared || [[ -s "$PREFIX/system.reg" ]]
}

require_update_prefix() {
    has_update_prefix ||
        die "No existing Wine prefix in $ROOT. Run install.sh to set one up."
}

migrate_launcher() (
    local desktop="${XDG_DATA_HOME:-$HOME/.local/share}/applications/altium-wine-linux.desktop"
    local root_arg new_script line temporary exe startup_class changed=0 needs_class=1
    local exe_arg=' "ALTIUM_WINE_EXE=([^"]+)" '
    [[ -f $desktop && ! -L $desktop ]] || return 0
    if grep -q '^StartupWMClass=' "$desktop"; then needs_class=0; fi
    root_arg="$(desktop_quote "ALTIUM_WINE_ROOT=$ROOT")"
    new_script="$(desktop_quote "$ROOT/kits/current/altium-wine.sh")"
    temporary="$(mktemp -- "${desktop}.XXXXXX")"
    trap 'rm -f -- "$temporary"' EXIT
    while IFS= read -r line || [[ -n $line ]]; do
        # Only migrate the command written by our launcher for this prefix.
        # Keep its other arguments and desktop entry fields verbatim.
        if [[ $line = "Exec=/usr/bin/env $root_arg "* &&
            $line = *' /bin/bash "'*'/altium-wine.sh" run %F' ]]; then
            if [[ $line != *" /bin/bash $new_script run %F" ]]; then
                line="${line% /bin/bash *} /bin/bash $new_script run %F"
                changed=1
            fi
            if (( needs_class )); then
                if [[ $line =~ $exe_arg ]]; then
                    exe="$(ALTIUM_WINE_EXE="${BASH_REMATCH[1]//%%/%}" get_altium)" || exe=""
                elif [[ $line != *' "ALTIUM_WINE_EXE='* ]]; then
                    exe="$(find_altium_exe)"
                else
                    exe=""
                fi
                if startup_class="$(desktop_startup_class "$exe")"; then
                    printf '%s\n' "$startup_class"
                    changed=1
                    needs_class=0
                fi
            fi
        fi
        printf '%s\n' "$line"
    done < "$desktop" > "$temporary"
    (( changed )) || return 0
    chmod --reference="$desktop" "$temporary"
    mv -T -- "$temporary" "$desktop"
    printf 'Updated launcher %s\n' "$desktop"
)

activate_release_kit() (
    local kit="$1" update="$2" launcher="$3" previous stage
    exec 4>"$ROOT/kits/.activation.lock"
    flock 4
    [[ ! -e "$ROOT/kits/current" || -L "$ROOT/kits/current" ]] ||
        die "Cannot activate the kit because $ROOT/kits/current is occupied."
    previous="$(release_kit "$ROOT/kits/current" 2>/dev/null)" || previous=""
    if [[ -n $previous ]] && version_is_newer "${previous##*/}" "${kit##*/}"; then
        kit="$previous"
    fi
    if [[ $previous != "$kit" ]]; then
        stage="$(mktemp -d -- "$ROOT/kits/.activate.XXXXXX")"
        trap 'rm -rf -- "$stage"' EXIT
        ln -s -- "${kit##*/}" "$stage/current"
        mv -Tf -- "$stage/current" "$ROOT/kits/current"
    fi
    if (( update && launcher )); then migrate_launcher; fi
    printf 'Active kit: %s\n' "${kit##*/}"
)

update_kit() (
    local check=0 launcher=1 latest tag current active called_kit stage checksum
    local update_root="${ALTIUM_WINE_ROOT:-}"
    while (( $# )); do
        case "$1" in
            --check) check=1 ;;
            --root) update_root="${2:?--root needs a directory}"; shift ;;
            --no-launcher) launcher=0 ;;
            --help|-h) usage; return ;;
            *) die "Unknown updater option: $1 (try update --help)" ;;
        esac
        shift
    done
    if [[ -z $update_root ]]; then
        called_kit="$(realpath -e -- "$KIT_DIR")"
        if [[ $called_kit = */kits/v* && -s "$called_kit/.release-sha256" ]]; then
            update_root="${called_kit%/kits/*}"
        fi
    fi
    set_paths "$update_root"
    # A cached redirect can point to the previous release after publication.
    latest="$(curl --proto '=https' --proto-redir '=https' -fLsSI --retry 2 -o /dev/null \
        -w '%{url_effective}' "$RELEASES_URL/latest?check=$(date +%s)")" ||
        die 'Could not check for the latest kit release.'
    tag="${latest#"$RELEASES_URL/tag/"}"
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'GitHub did not return a valid kit release tag.'
    active="$(release_kit "$ROOT/kits/current" 2>/dev/null)" || active=""
    current="${active:-$(release_kit "$KIT_DIR" || true)}"
    if [[ -n $current ]]; then
        printf 'Installed kit: %s\n' "${current##*/}"
    else
        printf 'Installed kit: no active release recorded\n'
    fi
    printf 'Latest kit:    %s\n' "$tag"
    if [[ -n $current ]] && ! version_is_newer "$tag" "${current##*/}" &&
        { (( check )) || [[ -n $active ]]; }; then
        printf 'The installed kit is up to date.\n'
        if (( ! check && launcher )); then activate_release_kit "$active" 1 1; fi
        return
    fi
    if (( check )); then
        if has_update_prefix; then
            printf 'Run bash altium-wine.sh update to install %s.\n' "$tag"
        else
            printf 'No Wine prefix in %s. Run install.sh to set one up.\n' "$ROOT"
        fi
        return
    fi
    require_update_prefix
    stage="$(mktemp -d)"
    trap 'rm -rf -- "$stage"' EXIT
    curl --proto '=https' --proto-redir '=https' -fLsS --retry 2 -o "$stage/SHA256SUMS" \
        "$RELEASES_URL/download/$tag/SHA256SUMS" || die "Could not download checksums for $tag."
    checksum="$(awk '$2 == "install.sh" || $2 == "*install.sh" { print $1 }' "$stage/SHA256SUMS")"
    [[ $checksum =~ ^[a-f0-9]{64}$ ]] || die "Missing or invalid install.sh checksum for $tag."
    download "$RELEASES_URL/download/$tag/install.sh" "$stage/install.sh" "$checksum" || exit 1
    local options=(--update --root "$ROOT")
    if (( ! launcher )); then options+=(--no-launcher); fi
    bash "$stage/install.sh" "${options[@]}"
)

make_launcher() (
    local exe directory desktop temporary extracted icon="" kit="$KIT_DIR"
    if ! exe="$(get_altium)" || [[ -z $exe ]]; then
        die 'Install Altium before creating the launcher.'
    fi
    directory="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    desktop="$directory/altium-wine-linux.desktop"
    mkdir -p -- "$directory"
    temporary="$(mktemp --suffix=.desktop "$directory/.altium.XXXXXX")"
    trap 'rm -f -- "$temporary" "$temporary.png" "$temporary.ico"' EXIT
    if extracted="$(python3 "$KIT_DIR/tools/exe-icon.py" "$exe" "$temporary" 2>/dev/null)"; then
        icon="$ROOT/altium-wine-launcher.${extracted##*.}"
        mkdir -p -- "$ROOT"
        replace_file "$extracted" "$icon"
    fi
    {
        printf '[Desktop Entry]\nVersion=1.0\nType=Application\nName=Altium Designer (Wine)\n'
        if [[ -n $icon ]]; then printf 'Icon=%s\n' "${icon//\\/\\\\}"; fi
        desktop_startup_class "$exe" || true
        printf 'Terminal=false\nCategories=Development;Electronics;\n'
        printf 'Exec=/usr/bin/env %s' "$(desktop_quote "ALTIUM_WINE_ROOT=$ROOT")"
        local setting
        for setting in ALTIUM_WINE_BIN ALTIUM_WINE_RENDERER ALTIUM_WINE_DESKTOP \
                ALTIUM_WINE_EXE ALTIUM_WINE_DXVK_DIR ALTIUM_WINE_NVIDIA \
                AD26_CEF_FALLBACK AD26_CEF_SOFTWARE_RENDERING; do
            [[ -z ${!setting:-} ]] || printf ' %s' "$(desktop_quote "$setting=${!setting}")"
        done
        if release_kit "$KIT_DIR" >/dev/null &&
            release_kit "$ROOT/kits/current" >/dev/null 2>&1; then
            kit="$ROOT/kits/current"
        fi
        printf ' /bin/bash %s run %%F\n' "$(desktop_quote "$kit/altium-wine.sh")"
    } > "$temporary"
    if command -v desktop-file-validate >/dev/null; then
        desktop-file-validate "$temporary"
    fi
    chmod 644 "$temporary"
    mv -T -- "$temporary" "$desktop"
    printf 'Created %s\n' "$desktop"
)

install_main() {
    local source="" skip=0 reinstall=0 launcher=1 build=0 update=0 exe kit active
    local args=("$@")
    while (( $# )); do
        case "$1" in
            --root) export ALTIUM_WINE_ROOT="${2:?--root needs a directory}"; shift ;;
            --altium-installer) source="${2:?--altium-installer needs a path}"; shift ;;
            --skip-altium) skip=1 ;;
            --update) update=1 ;;
            --reinstall-altium) reinstall=1 ;;
            --no-launcher) launcher=0 ;;
            --build-from-source) build=1 ;;
            --yes|--terminal) ;;
            -h|--help) usage; return ;;
            *) die "Unknown option: $1 (try --help)" ;;
        esac
        shift
    done
    set_paths
    kit="$(release_kit "$KIT_DIR")" || kit=""
    if [[ -n $kit ]] && active="$(release_kit "$ROOT/kits/current" 2>/dev/null)" &&
        version_is_newer "${active##*/}" "${kit##*/}"; then
        printf 'Using the newer active kit %s.\n' "${active##*/}"
        exec bash "$active/tools/altium-wine-linux.sh" kit-install "${args[@]}"
    fi
    if [[ -n $kit && -z $source ]] && (( ! skip && ! reinstall && ! build )) &&
        has_update_prefix; then
        update=1
    fi
    if (( update )); then
        if [[ -n $source ]] || (( reinstall || build )); then
            die '--update does not accept an Altium installer or --build-from-source.'
        fi
        if [[ -z $kit ]]; then
            if (( launcher )); then update_kit; else update_kit --no-launcher; fi
            return
        fi
        require_update_prefix
        # Install a newly pinned runner before activation. Prefix patches are
        # applied by the new kit at the next launch, without modifying a live prefix.
        ensure_wine
        activate_release_kit "$kit" 1 "$launcher"
        return
    fi
    if (( build )); then build_wine_modules; fi
    exe="$(get_altium)" || exe=""
    if (( skip )); then
        setup
    elif [[ -z $exe ]] || (( reinstall )); then
        [[ -n $source ]] || die 'Use --altium-installer PATH with the online setup executable or offline package.'
        install_altium "$source"
        exe="$(get_altium)" || exe=""
        [[ -n $exe ]] || die "Setup exited before Altium was installed. See $LOGS."
    fi
    if [[ -n $kit ]]; then activate_release_kit "$kit" 0 "$launcher"; fi
    if (( launcher )) && [[ -n $exe ]]; then make_launcher; fi
}

if [[ ${1:-} == help || ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $(uname -sm) == 'Linux x86_64' ]] || die 'This kit requires x86-64 Linux.'
entry_point="${1:-install}"
if (( $# )); then shift; fi
case "$entry_point" in
    kit-install) install_main "$@"; exit ;;
    update) update_kit "$@"; exit ;;
esac
set_paths
case "$entry_point" in
    setup) setup ;;
    build-wine) build_wine_modules "$@" ;;
    install) install_altium "$@" ;;
    run) run_altium "$@" ;;
    launcher) make_launcher ;;
    doctor)
        printf 'Linux %s\nPrefix %s\nWine %s\nLogs %s\n' "$(uname -rm)" "$PREFIX" "$WINE" "$LOGS"
        if [[ -x $WINE ]]; then "$WINE" --version; fi
        exe="$(get_altium)" || exe=""
        printf 'Altium %s\n' "${exe:-pending installation}"
        ;;
    wine) ensure_wine; exec "$WINE" "$@" ;;
    *) die "Unknown command: $entry_point (try help)" ;;
esac
