# MacPorts: the package manager these scripts use for build tools. It supports Intel and
# Apple Silicon Macs. Source this file from bash (3.2 or later) or zsh.
#
#   macports_install PORT...  install MacPorts if needed, then any of the ports not yet installed
#
# Root access goes through sudo: no prompt where sudo is set up that way, a Terminal prompt
# otherwise, and macOS's administrator dialog when there is no Terminal (the setup window).

MACPORTS_BIN="${MACPORTS_BIN:-/opt/local/bin}"
# MacPorts' release manager signs the installer packages with this Apple Developer ID team.
MACPORTS_TEAM='QTA3A3B7F3'

macports_admin() {  # macports_admin COMMAND [ARGS...]: run a command as root
    if sudo -n true 2>/dev/null || [ -t 0 ]; then
        sudo "$@"
        return $?
    fi
    local command="" arg
    for arg in "$@"; do
        command="$command '$(printf '%s' "$arg" | sed "s/'/'\\\\''/g")'"
    done
    osascript - "$command" <<'OSA'
on run argv
  do shell script (item 1 of argv) with administrator privileges
end run
OSA
}

ensure_macports() {  # install MacPorts from its signed release package for this macOS
    [ -x "$MACPORTS_BIN/port" ] && return 0
    local major release url work pkg
    major="$(sw_vers -productVersion | cut -d. -f1)"
    echo "Installing MacPorts (the package manager for the build tools)…"
    release="$(curl --proto '=https' -fsSL --retry 3 https://api.github.com/repos/macports/macports-base/releases/latest)" \
        || { echo "Couldn't look up the MacPorts release." >&2; return 1; }
    url="$(printf '%s\n' "$release" | grep -o '"browser_download_url": *"[^"]*-'"$major"'-[A-Za-z]*\.pkg"' \
        | sed 's/.*"\(https:[^"]*\)"$/\1/' | head -n 1)"
    [ -n "$url" ] || { echo "MacPorts has no installer for macOS $major yet." >&2; return 1; }
    work="$(mktemp -d /private/tmp/macports.XXXXXX)" || return 1
    pkg="$work/${url##*/}"
    # GitHub first, then MacPorts' own download server (the same signed package).
    if ! curl --proto '=https' -fL --retry 3 --progress-bar -o "$pkg" "$url" \
        && ! curl --proto '=https' -fL --retry 3 --progress-bar -o "$pkg" "https://distfiles.macports.org/MacPorts/${url##*/}"; then
        rm -rf "$work"; echo "Downloading MacPorts failed." >&2; return 1
    fi
    # Only install a package that Apple notarized and the MacPorts team signed.
    if ! spctl --assess --type install "$pkg" 2>/dev/null \
        || ! pkgutil --check-signature "$pkg" 2>/dev/null | grep -q "Developer ID Installer: .*($MACPORTS_TEAM)"; then
        rm -rf "$work"; echo "The MacPorts download isn't notarized and signed by the MacPorts team; not installing it." >&2; return 1
    fi
    macports_admin /usr/sbin/installer -pkg "$pkg" -target /
    rm -rf "$work"
    [ -x "$MACPORTS_BIN/port" ] || { echo "MacPorts didn't install." >&2; return 1; }
}

macports_install() {  # macports_install PORT...: install MacPorts if needed, then the missing ports
    ensure_macports || return 1
    local missing="" name
    for name in "$@"; do
        "$MACPORTS_BIN/port" -q installed "$name" 2>/dev/null | grep -q '(active)' || missing="$missing $name"
    done
    [ -z "$missing" ] && return 0
    echo "Installing$missing with MacPorts…"
    # Port names are plain words; eval splits the list the same way in bash and zsh.
    eval "macports_admin \"\$MACPORTS_BIN/port\" -N install $missing"
}
