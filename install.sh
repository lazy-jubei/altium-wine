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
#                            (needs Xcode Command Line Tools + Homebrew, ~15 min)
#   --root DIR               install location (default ~/AltiumWine, or $ALTIUM_WINE_ROOT)
#   --no-launcher            don't create ~/Applications/Altium Designer (Wine).app
#   --yes                    don't ask before starting
#   --uninstall              remove everything this installed
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
    local altium_src="" skip_altium=0 reinstall_altium=0 from_source=0 launcher=1 yes=0 uninstall=0

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
            -h|--help)          sed -n '2,24p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//'
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
        [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ] \
            || die "Building Wine needs Homebrew (https://brew.sh), for bison."
    fi

    # ---- the Altium installer -------------------------------------------------
    local x2 have_altium=0
    x2="$(find "$root/prefix/drive_c/Program Files/Altium" -maxdepth 2 -iname 'X2.EXE' 2>/dev/null | head -n 1)"
    [ -n "$x2" ] && have_altium=1
    if [ $have_altium = 1 ] && [ $reinstall_altium = 0 ]; then
        skip_altium=1
        say "Altium is already installed in $root/prefix; keeping it."
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
    if [ $yes = 0 ]; then
        [ "$TTY_IN" = /dev/tty ] || die "No terminal to confirm on; re-run with --yes."
        ask_yes "Continue?" || { say "Cancelled."; return 1; }
    fi

    # ---- Rosetta ----------------------------------------------------------------
    if [ $arm = 1 ] && ! arch -x86_64 /usr/bin/true 2>/dev/null; then
        say "Wine needs Rosetta 2."
        if [ $yes = 1 ] || { [ "$TTY_IN" = /dev/tty ] && ask_yes "Install Rosetta 2 now (accepts Apple's Rosetta license)?"; }; then
            softwareupdate --install-rosetta --agree-to-license || die "Rosetta install failed."
        else
            die "Rosetta 2 is required: softwareupdate --install-rosetta"
        fi
    fi

    # ---- kit + modules ------------------------------------------------------------
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
    say "Setting up Wine and the prefix"
    PATCHED_MODULES_DIR="$modules" bash "$aw" setup < "$TTY_IN" || die "Setup failed; see $kit/logs/LATEST-summary.txt"
    # An existing patched Wine is refreshed when this release's modules differ from it.
    if [ -n "$modules" ] && ! patched_matches "$root/wine-patched/PATCHES" "$modules/SHA256SUMS"; then
        say "Updating the patched Wine"
        bash "$kit/build-patched-wine.sh" --modules "$modules" < "$TTY_IN" || die "Updating the patched Wine failed."
    fi
    if [ ! -f "$root/prefix/.altium-kit-deps" ]; then
        bash "$aw" deps < "$TTY_IN" || warn "winetricks had problems; see $kit/logs. Altium may show some text in fallback fonts."
    fi

    # ---- Altium -------------------------------------------------------------------------
    if [ $skip_altium = 0 ]; then
        local setup_dir="$altium_src"
        case "$altium_src" in
            *.zip|*.ZIP)
                setup_dir="$dl/altium-offline-setup"
                say "Unpacking $(basename "$altium_src") (several GB, takes a few minutes)"
                rm -rf "$setup_dir"; mkdir -p "$setup_dir"
                ditto -x -k "$altium_src" "$setup_dir" || die "Couldn't unzip $altium_src"
                ;;
        esac
        local inst
        inst="$(find "$setup_dir" -maxdepth 3 -name 'Installer.Exe' 2>/dev/null | head -n 1)"
        [ -n "$inst" ] || die "No Installer.Exe in $setup_dir"
        say "Starting the Altium installer. In it:"
        echo "   * License Agreement page: Advanced Settings > untick 'Unified Sign In', then sign in"
        echo "     with the form inside the installer."
        echo "   * If it stops responding, a dialog is probably behind it (Mission Control shows it)."
        bash "$aw" install "$(dirname "$inst")" < "$TTY_IN" || warn "The installer exited with an error; see $kit/logs/LATEST-summary.txt"
        case "$setup_dir" in "$dl"/*) rm -rf "$setup_dir" ;; esac  # our unzipped copy only
        x2="$(find "$root/prefix/drive_c/Program Files/Altium" -maxdepth 2 -iname 'X2.EXE' 2>/dev/null | head -n 1)"
        [ -n "$x2" ] && have_altium=1
    fi

    if [ $launcher = 1 ] && [ $have_altium = 1 ]; then
        bash "$aw" launcher < "$TTY_IN" || warn "Couldn't create the launcher app."
    fi

    # ---- done ---------------------------------------------------------------------------
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
        if [ -d "$d" ] && find "$d" -maxdepth 2 -name 'Installer.Exe' 2>/dev/null | grep -q .; then
            echo "$d"; return 0
        fi
    done
    for d in $(ls -t "$HOME"/Downloads/*Altium*Designer*.zip 2>/dev/null | tr ' ' '\001'); do
        echo "$d" | tr '\001' ' '; return 0
    done
    return 0
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
