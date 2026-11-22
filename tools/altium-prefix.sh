# Shared prefix lookups for the macOS and Linux launchers.
# The caller supplies PREFIX and WINE.

# The installed Altium: the newest X2.EXE (Altium 18 and later, 64-bit, Program Files), else
# DXP.EXE (Altium 17 and older, 32-bit, Program Files (x86)).
find_altium_exe() {
    local c="$PREFIX/drive_c" exe
    exe="$(find "$c/Program Files/Altium" -maxdepth 2 -iname 'X2.EXE' 2>/dev/null | sort | tail -n 1)"
    [ -n "$exe" ] || exe="$(find "$c/Program Files (x86)/Altium" "$c/Program Files/Altium" -maxdepth 2 \
        -iname 'DXP.EXE' 2>/dev/null | sort | tail -n 1)"
    echo "$exe"
}

# Return the installed AD26 build profile for the selected executable.
find_ad26_profile() {
    local directory="${1#"$PREFIX"/drive_c/}"
    directory="${directory%/*}"
    # Match the selected executable to its installer record. Other versions and
    # other installations in this prefix have separate preference keys.
    WINEDEBUG=-all "$WINE" reg query 'HKLM\Software\Altium\Builds' /s /reg:64 2>/dev/null |
        LC_ALL=C ALTIUM_INSTALL_PATH="C:\\${directory//\//\\}" awk '
            function record() {
                if (profile ~ /^Altium Designer \{[[:xdigit:]-]+\}$/ &&
                    tolower(installed) == "true" && version ~ /^26\./ && tolower(path) == expected) {
                    match_count++
                    selected = profile
                }
            }
            BEGIN { expected = tolower(ENVIRON["ALTIUM_INSTALL_PATH"]) }
            { sub(/\r$/, "") }
            /^HKEY_LOCAL_MACHINE\\/ {
                record()
                profile = $0
                sub(/^HKEY_LOCAL_MACHINE\\Software\\Altium\\Builds\\/, "", profile)
                installed = version = path = ""
                next
            }
            $1 == "Installed" && $2 == "REG_SZ" { installed = $3 }
            $1 == "Version" && $2 == "REG_SZ" { version = $3 }
            $1 == "ProgramsInstallPath" && $2 == "REG_SZ" {
                sub(/^[ \t]*ProgramsInstallPath[ \t]+REG_SZ[ \t]+/, "")
                path = $0
                sub(/\\$/, "", path)
            }
            END { record(); if (match_count == 1) print selected }
        '
}
