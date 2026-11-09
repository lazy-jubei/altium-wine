#!/bin/bash
# install.sh - install Altium Designer on an Apple Silicon Mac under Wine (Altium-on-Wine kit).
#
#   curl -fsSL <release-url>/install.sh | bash
#   curl -fsSL <release-url>/install.sh -o install.sh && bash install.sh [options]
#   bash wine-kit/install.sh [options]          # from a kit checkout (builds Wine from source)
#
# Options:
#   --altium-installer PATH  the Altium offline setup folder or its .zip
#                            (default: look in ~/Downloads, then ask)
#   --skip-altium            set up Wine only; run the Altium installer later
#   --reinstall-altium       run the Altium installer even if Altium is already installed
#   --build-from-source      compile the patched Wine modules instead of downloading them
#                            (needs Xcode Command Line Tools + MacPorts, ~15 min)
#   --root DIR               install location (default ~/AltiumWine, or $ALTIUM_WINE_ROOT)
#   --no-launcher            don't create ~/Applications/Altium Designer (Wine).app
#   --yes                    don't ask before starting
#   --uninstall              remove everything this installed
#   --terminal               ask in Terminal instead of opening the setup window
#
# Everything goes under the install location; nothing is installed system-wide except Rosetta 2
# (asked first). Re-running updates the kit and patched Wine and keeps your Altium install.
# Written for macOS's /bin/bash 3.2. The whole script is one function, called on the last line,
# so `curl | bash` never runs a half-downloaded script.

set -u

# ---- release stamp: make-release.sh fills these in ---------------------------
KIT_VERSION="dev"
RELEASE_URL=""
KIT_SHA256=""
MODULES_SHA256=""
# ---- end release stamp --------------------------------------------------------

main() {
    local root="${ALTIUM_WINE_ROOT:-}"
    local altium_src="" skip_altium=0 reinstall_altium=0 from_source=0 launcher=1 yes=0 uninstall=0 terminal=0
    local all_args
    all_args=("$@")

    while [ $# -gt 0 ]; do
        case "$1" in
            --altium-installer) altium_src="${2:?--altium-installer needs a path}"; shift 2 ;;
            --skip-altium)      skip_altium=1; shift ;;
            --reinstall-altium) reinstall_altium=1; shift ;;
            --build-from-source) from_source=1; shift ;;
            --root)             root="${2:?--root needs a directory}"; shift 2 ;;
            --no-launcher)      launcher=0; shift ;;
            --yes|-y)           yes=1; shift ;;
            --uninstall)        uninstall=1; shift ;;
            --terminal)         terminal=1; shift ;;
            -h|--help)          sed -n '2,25p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'
                                [ -n "${BASH_SOURCE[0]:-}" ] || echo "See the comment at the top of install.sh."
                                return 0 ;;
            *) die "Unknown option: $1 (try --help)" ;;
        esac
    done

    # Prompts and child processes read the terminal, never stdin: under `curl | bash`, stdin is
    # the script itself.
    TTY_IN=/dev/null
    if (exec </dev/tty) 2>/dev/null; then TTY_IN=/dev/tty; fi

    say "Altium Designer on Wine - installer $KIT_VERSION"

    # ---- where is the kit, and where does it install? ---------------------------
    local here="" kit
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [ -z "$RELEASE_URL" ]; then
        [ -n "$here" ] && [ -f "$here/altium-wine.sh" ] \
            || die "This install.sh isn't from a release (no RELEASE_URL) and isn't inside a kit checkout."
        # The kit a release installed remembers its location in config.local.sh.
        if [ -z "$root" ] && [ -f "$here/config.local.sh" ]; then
            root="$(sed -n 's/^WORK_ROOT=//p' "$here/config.local.sh" | tail -n 1)"
        fi
    fi
    [ -n "$root" ] || root="$HOME/AltiumWine"
    case "$root" in /*) ;; *) root="$PWD/$root" ;; esac
    root="${root%/}"
    if [ -n "$RELEASE_URL" ]; then
        kit="$root/kit"
    else
        # A kit checkout, or the kit a release installed: no module downloads from here.
        kit="$here"
        [ -d "$root/wine-patched" ] || from_source=1
        say "Using the kit in $kit"
    fi

    # In a desktop session, the rest happens in the setup window, which runs this script again.
    if [ "$UI" = terminal ] && [ $terminal = 0 ] && [ $yes = 0 ] && [ $uninstall = 0 ] && window_possible; then
        if open_window "$root" "$here" ${all_args[@]+"${all_args[@]}"}; then
            say "The setup window is open. You can close this Terminal window."
            return 0
        fi
    fi
    if [ "$UI" = app ]; then
        trap 'ui_exit $?' EXIT
        trap 'exit 130' HUP INT TERM
        ui_stage installer "checking this Mac"
    fi

    if [ $uninstall = 1 ]; then
        [ -f "$kit/altium-wine.sh" ] || die "No kit at $kit; nothing to uninstall there."
        ALTIUM_WINE_ROOT="$root" bash "$kit/altium-wine.sh" uninstall < "$TTY_IN"
        return $?
    fi

    # ---- checks ---------------------------------------------------------------
    [ "$(uname -s)" = "Darwin" ] || die "This is for macOS."
    local arm=0 osver
    [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = "1" ] && arm=1
    [ $arm = 1 ] || warn "This Mac isn't Apple Silicon. The kit was only tested on Apple Silicon."
    osver="$(sw_vers -productVersion)"
    [ "${osver%%.*}" -ge 13 ] 2>/dev/null || warn "macOS $osver is older than anything tested (macOS 15)."
    [ ${#root} -le 70 ] || die "Install path too long for Wine (${#root} chars): $root"
    case "$root" in *" "*) die "Install path can't contain spaces: $root" ;; esac

    local free_gb need_gb=12
    [ $skip_altium = 1 ] || need_gb=30
    mkdir -p "$root" || die "Can't create $root"
    free_gb="$(df -g "$root" | awk 'NR==2 {print $4}')"
    [ "${free_gb:-0}" -ge $need_gb ] 2>/dev/null \
        || warn "Only ${free_gb:-?} GB free; Wine + Altium need about $need_gb GB."

    if [ $from_source = 1 ]; then
        xcode-select -p >/dev/null 2>&1 || die "Building Wine needs the Xcode Command Line Tools. Run: xcode-select --install"
    fi

    if [ "$UI" = app ]; then
        ui_message "This installs Altium Designer on your Mac.

You only need to do two things:
1. Choose the Altium offline installer you downloaded from your Altium account.
2. Sign in inside the Altium installer when it opens.

Everything else runs on its own. You need your own Altium license." 'Start' 'Welcome'
    fi

    # ---- the Altium installer -------------------------------------------------
    local x2 have_altium=0
    x2="$(find_altium_exe "$(prefix_dir "$root")")"
    [ -n "$x2" ] && have_altium=1
    if [ $have_altium = 1 ] && [ $reinstall_altium = 0 ]; then
        skip_altium=1
        say "Altium is already installed in $root/prefix; keeping it."
    fi
    if [ "$UI" = app ] && [ $skip_altium = 0 ] && [ -z "$altium_src" ]; then
        altium_src="$(ui_choose_installer "$(find_altium_installer)")" || exit $?
    fi
    if [ $skip_altium = 0 ] && [ -z "$altium_src" ]; then
        altium_src="$(find_altium_installer)"
        if [ -n "$altium_src" ]; then
            say "Found the Altium offline installer: $altium_src"
            if [ $yes = 0 ] && [ "$TTY_IN" = /dev/tty ] && ! ask_yes "Use it?"; then altium_src=""; fi
        fi
        if [ -z "$altium_src" ] && [ "$TTY_IN" = /dev/tty ] && [ $yes = 0 ]; then
            echo "Download the Altium Designer offline installer from your Altium account"
            echo "(altium.com > Downloads > Offline installation), then give its folder or .zip."
            printf 'Path (empty to skip for now): '
            read -r altium_src < /dev/tty || altium_src=""
            altium_src="${altium_src%\"}"; altium_src="${altium_src#\"}"; altium_src="${altium_src%/}"
            case "$altium_src" in "~/"*) altium_src="$HOME/${altium_src#\~/}" ;; esac
        fi
        if [ -z "$altium_src" ]; then
            skip_altium=1
            say "No Altium installer given; setting up Wine only."
        elif [ ! -e "$altium_src" ]; then
            die "Not found: $altium_src"
        fi
    fi

    # ---- confirm --------------------------------------------------------------
    echo
    echo "  Install location:  $root"
    if [ -n "$RELEASE_URL" ]; then
        echo "  Downloads:         Altium-on-Wine kit $KIT_VERSION + patched Wine modules (from $RELEASE_URL),"
    else
        echo "  Downloads:         Wine 11.16 sources + llvm-mingw (the patched modules are built here),"
    fi
    echo "                     wine-staging 11.16 (~185 MB, github.com/Gcenx), DXVK-macOS (~4 MB),"
    echo "                     core fonts via winetricks"
    [ $skip_altium = 0 ] && echo "  Altium installer:  $altium_src"
    [ $launcher = 1 ] && echo "  Launcher:          ~/Applications/Altium Designer (Wine).app"
    echo
    echo "  Altium doesn't support Wine; this is unofficial. You need your own Altium license."
    echo
    if [ $yes = 0 ] && [ "$UI" != app ]; then
        [ "$TTY_IN" = /dev/tty ] || die "No terminal to confirm on; re-run with --yes."
        ask_yes "Continue?" || { say "Cancelled."; return 1; }
    fi

    # ---- Rosetta ----------------------------------------------------------------
    if [ $arm = 1 ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        say "Wine needs Rosetta 2."
        if [ "$UI" = app ]; then
            ui_message "Wine needs Rosetta 2, Apple's tool for running Intel apps. Installing it accepts Apple's Rosetta license." 'Install Rosetta' 'Install Rosetta 2'
        fi
        if [ $yes = 1 ] || [ "$UI" = app ] || { [ "$TTY_IN" = /dev/tty ] && ask_yes "Install Rosetta 2 now (accepts Apple's Rosetta license)?"; }; then
            softwareupdate --install-rosetta --agree-to-license || die "Rosetta install failed."
        else
            die "Rosetta 2 is required: softwareupdate --install-rosetta"
        fi
    fi

    # ---- kit + modules ------------------------------------------------------------
    ui_stage wine "downloading Wine"
    WINE_STARTED=1
    local dl="$root/downloads" modules=""
    mkdir -p "$dl"
    if [ -n "$RELEASE_URL" ]; then
        fetch "$RELEASE_URL/altium-wine-kit-$KIT_VERSION.tar.gz" "$dl/altium-wine-kit-$KIT_VERSION.tar.gz" "$KIT_SHA256"
        rm -rf "$root/kit.new"; mkdir -p "$root/kit.new"
        tar -xzf "$dl/altium-wine-kit-$KIT_VERSION.tar.gz" -C "$root/kit.new" --strip-components 1 || die "Kit extract failed."
        [ -f "$root/kit.new/altium-wine.sh" ] || die "Kit archive has no altium-wine.sh"
        if [ -d "$kit" ]; then  # update: keep logs and local settings
            if [ -d "$kit/logs" ]; then
                rmdir "$root/kit.new/logs" 2>/dev/null || true
                mv "$kit/logs" "$root/kit.new/logs" || die "Couldn't preserve existing logs."
            fi
            [ -f "$kit/config.local.sh" ] && cp "$kit/config.local.sh" "$root/kit.new/"
            rm -rf "$kit"
        fi
        mv "$root/kit.new" "$kit" || die "Couldn't move the kit into place."
        say "Kit $KIT_VERSION in $kit"

        if [ $from_source = 0 ]; then
            fetch "$RELEASE_URL/altium-wine-modules-$KIT_VERSION.tar.gz" "$dl/altium-wine-modules-$KIT_VERSION.tar.gz" "$MODULES_SHA256"
            modules="$dl/modules-$KIT_VERSION"
            rm -rf "$modules"; mkdir -p "$modules"
            tar -xzf "$dl/altium-wine-modules-$KIT_VERSION.tar.gz" -C "$modules" --strip-components 1 || die "Modules extract failed."
            ( cd "$modules" && shasum -a 256 -c SHA256SUMS >/dev/null ) || die "Module checksums don't match."
        fi
    fi
    if [ "$root" != "$HOME/AltiumWine" ]; then
        printf '# Written by install.sh: where this kit keeps Wine, the prefix and downloads.\nWORK_ROOT=%q\n' "$root" > "$kit/config.local.sh"
    fi

    local aw="$kit/altium-wine.sh"
    export ALTIUM_WINE_ROOT="$root"

    # ---- Wine + prefix --------------------------------------------------------------
    ui_stage wine "setting up Wine"
    say "Setting up Wine and the prefix"
    PATCHED_MODULES_DIR="$modules" bash "$aw" setup < "$TTY_IN" || die "Setup failed; see $kit/logs/LATEST-summary.txt"
    # An existing patched Wine is refreshed when this release's modules differ from it.
    if [ -n "$modules" ] && ! patched_matches "$root/wine-patched/PATCHES" "$modules/SHA256SUMS"; then
        say "Updating the patched Wine"
        bash "$kit/build-patched-wine.sh" --modules "$modules" < "$TTY_IN" || die "Updating the patched Wine failed."
    fi
    if [ ! -f "$(prefix_dir "$root")/.altium-kit-deps" ]; then
        ui_stage wine "installing fonts"
        bash "$aw" deps < "$TTY_IN" || warn "winetricks had problems; see $kit/logs. Altium may show some text in fallback fonts."
    fi

    # ---- Altium -------------------------------------------------------------------------
    if [ $skip_altium = 0 ]; then
        local setup_dir="$altium_src"
        case "$altium_src" in
            *.zip|*.ZIP)
                setup_dir="$dl/altium-offline-setup"
                ui_stage altium "unpacking the Altium installer"
                say "Unpacking $(basename "$altium_src") (several GB, takes a few minutes)"
                rm -rf "$setup_dir"; mkdir -p "$setup_dir"
                ditto -x -k "$altium_src" "$setup_dir" || die "Couldn't unzip $altium_src"
                ;;
        esac
        local inst
        inst="$(find "$setup_dir" -maxdepth 3 \( -iname 'Installer.Exe' -o -iname 'AltiumDesigner*Setup.exe' \) 2>/dev/null | head -n 1)"
        [ -n "$inst" ] || die "No Altium installer in $setup_dir"
        say "Starting the Altium installer. In it:"
        echo "   * License Agreement page: Advanced Settings > untick 'Unified Sign In', then sign in"
        echo "     with the form inside the installer."
        echo "   * If it stops responding, a dialog is probably behind it (Mission Control shows it)."
        ui_stage altium "running the Altium installer"
        ui_wait 'Install Altium' "Follow the Altium installer in its own window.

On the License Agreement page, click Advanced Settings and untick Unified Sign In. Then sign in in the installer.

If the installer stops responding, a dialog may be hidden behind it. Mission Control shows it." 'Waiting for the Altium installer to finish.'
        bash "$aw" install "$inst" < "$TTY_IN" || warn "The installer exited with an error; see $kit/logs/LATEST-summary.txt"
        case "$setup_dir" in "$dl"/*) rm -rf "$setup_dir" ;; esac  # our unzipped copy only
        x2="$(find_altium_exe "$(prefix_dir "$root")")"
        [ -n "$x2" ] && have_altium=1
        [ $have_altium = 1 ] || [ "$UI" != app ] || die "Altium wasn't installed. The Altium installer may have been closed early."
    fi

    # Altium 17 and older (32-bit DXP.EXE) load .NET extensions that Wine Mono can't host.
    case "$x2" in
        *DXP.EXE|*dxp.exe)
            if ! grep -qw dotnet48 "$(prefix_dir "$root")/.altium-kit-deps" 2>/dev/null; then
                ui_stage finish "installing .NET 4.8 for Altium 17"
                say "Installing Microsoft .NET Framework 4.8 for Altium 17 (about 5 minutes)"
                bash "$aw" deps dotnet48 < "$TTY_IN" || warn ".NET 4.8 install had problems; Altium 17's .NET extensions may not load."
            fi
            ;;
    esac

    if [ $launcher = 1 ] && [ $have_altium = 1 ]; then
        ui_stage finish "adding Altium to Applications"
        bash "$aw" launcher < "$TTY_IN" || warn "Couldn't create the launcher app."
    fi

    # ---- done ---------------------------------------------------------------------------
    if [ "$UI" = app ]; then
        if [ $have_altium = 1 ]; then
            # Started apart from the window, so closing the window leaves Altium running.
            ui_stage finish "opening Altium"
            # Altium may already be open (from the Altium installer's last page).
            if ! pgrep -f 'X2\.EXE|DXP\.EXE' >/dev/null 2>&1; then
                nohup bash "$aw" run < /dev/null > /dev/null 2>&1 &
            fi
            ui_emit finished "Altium is opening. Sign in through the browser when it asks, then quit Altium and open it again. Your sign-in shows up after that restart.

Next time, open Altium Designer (Wine) from Applications."
        else
            ui_emit finished "Wine is ready. Run setup again with your Altium offline installer to install Altium."
        fi
        return 0
    fi
    echo
    say "Done."
    if [ $have_altium = 1 ]; then
        if [ $launcher = 1 ]; then
            echo "  Start Altium from ~/Applications/Altium Designer (Wine).app (Spotlight finds it),"
            echo "  or in Terminal:  bash \"$aw\" run"
        else
            echo "  Start Altium:  bash \"$aw\" run"
        fi
        echo "  First start: sign in through the browser, then quit and start Altium again (the"
        echo "  session only shows up after a restart). Turn the Home Page off in Preferences >"
        echo "  System > General; it stays blank under Wine."
    else
        echo "  Wine is ready. Install Altium later with:"
        echo "    bash \"$kit/install.sh\" --altium-installer <offline setup folder or .zip>"
    fi
    echo "  Logs: $kit/logs   Uninstall: bash \"$kit/install.sh\" --uninstall"
}

# ---- setup window -------------------------------------------------------------------------
# With ALTIUM_INSTALLER_UI=app this script runs inside the setup window (tools/AltiumInstaller.swift):
# lines on stderr that start with "@@sw<TAB>" are prompts and progress, and answers come back
# one line at a time on stdin. Fields are tab-separated, with \n, \t and \\ escaped.
UI="${ALTIUM_INSTALLER_UI:-terminal}"
UI_STAGE="starting"
WINE_STARTED=0

ui_emit() {
    [ "$UI" = app ] || return 0
    local out="@@sw" field
    for field in "$@"; do
        field="${field//\\/\\\\}"
        field="${field//$'\t'/\\t}"
        field="${field//$'\n'/\\n}"
        out="$out"$'\t'"$field"
    done
    printf '%s\n' "$out" >&2
}

ui_read() {  # one answer from the window; Quit (or the window closing) stops setup
    local reply
    IFS= read -r reply || reply='@@quit'
    [ "$reply" != '@@quit' ] || { echo "Setup cancelled." >&2; exit 130; }
    printf '%s\n' "$reply"
}

ui_stage() {  # ui_stage STEP TEXT: steps are installer, wine, altium, finish
    UI_STAGE="$2"
    ui_emit stage "$1" "$2"
}

ui_message() {  # ui_message TEXT [BUTTON] [TITLE]: a page with one button (and Quit)
    [ "$UI" = app ] || return 0
    ui_emit message "${2:-Continue}" "${3:-}" "$1"
    ui_read >/dev/null || exit $?
}

ui_wait() {  # ui_wait TITLE TEXT STATUS: a page while something runs, with no button
    ui_emit wait "$1" "$2" "$3"
}

ui_choose_installer() {  # ui_choose_installer DEFAULT: prints the chosen offline setup folder or .zip
    local chosen="$1" text="Choose the Altium Designer offline installer you downloaded from your Altium account (altium.com > Downloads > Offline installation). It can be the folder or the .zip."
    while true; do
        ui_emit choose "$chosen" "$text"
        chosen="$(ui_read)" || exit $?
        case "$chosen" in
            *.zip|*.ZIP) [ -f "$chosen" ] && { printf '%s\n' "$chosen"; return 0; } ;;
            *) if [ -d "$chosen" ] && find "$chosen" -maxdepth 3 \( -iname 'Installer.Exe' -o -iname 'AltiumDesigner*Setup.exe' \) 2>/dev/null | grep -q .; then
                   printf '%s\n' "$chosen"; return 0
               fi ;;
        esac
        text="No Altium installer was found there. Choose the offline installer folder (it contains Installer.exe) or its .zip."
    done
}

ui_exit() {  # EXIT trap in the window: stop the Wine setup started, and report a failure
    local rc="$1"
    if [ "$rc" != 0 ]; then
        stop_wine
        [ "$rc" = 130 ] || ui_emit failed "$UI_STAGE"
    fi
}

stop_wine() {
    [ "$WINE_STARTED" = 1 ] || return 0
    local ws prefix
    prefix="$(prefix_dir "${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}")"
    for ws in "${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}"/wine-patched/Wine*.app/Contents/Resources/wine/bin/wineserver \
              "${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}"/wine/Wine*.app/Contents/Resources/wine/bin/wineserver; do
        [ -x "$ws" ] && WINEPREFIX="$prefix" "$ws" -k 2>/dev/null
    done
    return 0
}

prefix_dir() {  # prefix_dir ROOT: the Wine prefix, in the kit's disk image (mounted here if needed)
    local root="$1" image="$1/altium-wine.sparsebundle" volume="$1/volume"
    if [ -d "$root/prefix/drive_c" ] && [ ! -d "$image" ]; then echo "$root/prefix"; return 0; fi
    if [ -d "$image" ] && ! mount | grep -qF " on $volume ("; then
        mkdir -p "$volume"
        hdiutil attach -quiet "$image" -mountpoint "$volume" -nobrowse -noverify -noautofsck -owners on >/dev/null 2>&1 || true
    fi
    echo "$volume/prefix"
}

window_possible() {  # a desktop session, and this script is a file the window can run again
    [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] || return 1
    [ -z "${SSH_CONNECTION:-}" ] || return 1
    [ "$(launchctl managername 2>/dev/null)" = Aqua ] || return 1
    xcrun --find swiftc >/dev/null 2>&1  # the Command Line Tools build the window
}

open_window() {  # open_window ROOT HERE [ARGS...]: build the setup window and open it
    local root="$1" here="$2" src app bin log script arg
    shift 2
    mkdir -p "$root/tools" "$root/downloads"
    app="$root/tools/Altium Designer Installer.app"
    bin="$app/Contents/MacOS/Altium Designer Installer"
    log="$root/tools/installer-window-build.log"
    if [ -n "$RELEASE_URL" ]; then
        # The window's source comes in the kit archive.
        ( fetch "$RELEASE_URL/altium-wine-kit-$KIT_VERSION.tar.gz" "$root/downloads/altium-wine-kit-$KIT_VERSION.tar.gz" "$KIT_SHA256" ) || return 1
        rm -rf "$root/tools/window-src"; mkdir -p "$root/tools/window-src"
        tar -xzf "$root/downloads/altium-wine-kit-$KIT_VERSION.tar.gz" -C "$root/tools/window-src" --strip-components 2 \
            --include '*/tools/AltiumInstaller.swift' 2>/dev/null || return 1
        src="$root/tools/window-src/AltiumInstaller.swift"
    else
        src="$here/tools/AltiumInstaller.swift"
    fi
    [ -f "$src" ] || return 1
    if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
        say "Preparing the setup window"
        rm -rf "$app"; mkdir -p "$app/Contents/MacOS"
        cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Altium Designer Installer</string>
  <key>CFBundleIdentifier</key><string>io.github.lazy-jubei.altium-wine-installer</string>
  <key>CFBundleName</key><string>Altium Designer Installer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
        if ! xcrun swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13" -o "$bin" "$src" > "$log" 2>&1; then
            rm -rf "$app"
            warn "The setup window couldn't be built (see $log); using Terminal instead."
            return 1
        fi
        codesign --force --sign - "$app" >/dev/null 2>&1 || true
    fi
    # A release's install.sh is copied next to its downloads, so the window doesn't depend on
    # where it was saved; a kit checkout runs its own install.sh.
    if [ -n "$RELEASE_URL" ]; then
        script="$root/downloads/install.sh"
        if [ "${BASH_SOURCE[0]}" != "$script" ]; then cp "${BASH_SOURCE[0]}" "$script" || return 1; fi
    else
        script="$here/install.sh"
    fi
    local open_args
    open_args=(--script "$script" --root "$root")
    for arg in "$@"; do open_args+=(--arg "$arg"); done
    open "$app" --args "${open_args[@]}"
}

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*"; exit 1; }

ask_yes() {
    local reply
    printf '%s [y/N] ' "$1"
    read -r reply < "$TTY_IN" || return 1
    case "$reply" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

fetch() {  # fetch URL FILE SHA256 - download (reusing a verified copy) and verify
    local url="$1" file="$2" want="$3"
    [ -n "$want" ] || die "No checksum for $(basename "$file") in this install.sh."
    if [ -s "$file" ] && [ "$(shasum -a 256 "$file" | awk '{print $1}')" = "$want" ]; then return 0; fi
    say "Downloading $(basename "$file")"
    curl -fL --progress-bar -o "$file.part" "$url" || { rm -f "$file.part"; die "Download failed: $url"; }
    [ "$(shasum -a 256 "$file.part" | awk '{print $1}')" = "$want" ] \
        || { rm -f "$file.part"; die "Checksum mismatch for $(basename "$file"); not using it."; }
    mv "$file.part" "$file"
}

find_altium_installer() {  # newest Altium offline setup folder (or zip) in ~/Downloads
    local d
    for d in $(ls -dt "$HOME"/Downloads/*Altium*Designer* 2>/dev/null | tr ' ' '\001'); do
        d="$(echo "$d" | tr '\001' ' ')"
        if [ -d "$d" ] && find "$d" -maxdepth 2 \( -iname 'Installer.Exe' -o -iname 'AltiumDesigner*Setup.exe' \) 2>/dev/null | grep -q .; then
            echo "$d"; return 0
        fi
    done
    for d in $(ls -t "$HOME"/Downloads/*Altium*Designer*.zip 2>/dev/null | tr ' ' '\001'); do
        echo "$d" | tr '\001' ' '; return 0
    done
    return 0
}

find_altium_exe() {  # find_altium_exe PREFIX: X2.EXE (Altium 18+) or DXP.EXE (17 and older)
    local c="$1/drive_c" exe
    exe="$(find "$c/Program Files/Altium" -maxdepth 2 -iname 'X2.EXE' 2>/dev/null | head -n 1)"
    [ -n "$exe" ] || exe="$(find "$c/Program Files (x86)/Altium" -maxdepth 2 -iname 'DXP.EXE' 2>/dev/null | head -n 1)"
    echo "$exe"
}

patched_matches() {  # patched_matches PATCHES SHA256SUMS - every module hash appears in the manifest
    local manifest="$1" sums="$2" h
    [ -f "$manifest" ] && [ -f "$sums" ] || return 1
    for h in $(awk '{print $1}' "$sums"); do
        grep -q "$h" "$manifest" || return 1
    done
    return 0
}

main "$@"
