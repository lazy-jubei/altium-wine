#!/bin/bash
set -euo pipefail

action="$1"
prefix="$2"
wine="$3"
sources="$(cd "$(dirname "$0")" && pwd)"
system="$prefix/drive_c/Program Files/Altium/AD26/System"
provider=InteractiveProperties.Providers.PCB.DataModel.dll
helper=RoutingHandoffGuard.dll
backup="$prefix/.ad26-routing-guard"
original_sha=1efb9c9980ccbf035727d3883c567c89f254597a901c6c64069806de0e940f75

fail() { echo "$*" >&2; exit 1; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

require_closed() {
    local pid process
    while read -r pid; do
        process="$(ps -p "$pid" -o comm=)" || continue
        case "$process" in
            *[Xx]2.[Ee][Xx][Ee]) fail "Quit Altium before changing the routing provider." ;;
        esac
    done < <(lsof -t -- "$system/../X2.EXE" "$system/$provider" 2>/dev/null)
}

replace_file() (
    temporary="$(mktemp "$system/.routing-guard.XXXXXXXX")"
    trap '[[ ! -e "$temporary" ]] || rm -f "$temporary"' EXIT
    cp -p "$1" "$temporary"
    mv -f "$temporary" "$system/$2"
)

[[ -f "$system/$provider" ]] || fail "Altium 26 PCB provider not found."
case "$action" in install|restore) ;; *) fail "Use routing-guard install or routing-guard restore." ;; esac
require_closed
mkdir -p "$backup"
lock="$backup/lock"
mkdir "$lock" || fail "Another routing guard operation is in progress."
stage=""
cleanup() {
    if [[ -n "$stage" ]]; then
        rm -f "$stage/$provider" "$stage/$helper" "$stage/Mono.Cecil.dll" "$stage/PatchRoutingProvider.exe"
        rmdir "$stage"
    fi
    rmdir "$lock"
}
trap cleanup EXIT
installed_sha="$(sha "$system/$provider")"
if [[ "$installed_sha" != "$original_sha" ]]; then
    [[ -f "$backup/provider.sha256" && "$installed_sha" == "$(cat "$backup/provider.sha256")" ]] ||
        fail "This PCB provider does not match the supported Altium 26.12.2 build."
fi

if [[ "$action" == restore ]]; then
    if [[ "$installed_sha" != "$original_sha" ]]; then
        [[ -f "$backup/$provider" && "$(sha "$backup/$provider")" == "$original_sha" ]] ||
            fail "The original PCB provider backup is missing or has changed."
        replace_file "$backup/$provider" "$provider"
    fi
    if [[ -f "$system/$helper" && -f "$backup/helper.sha256" &&
          "$(sha "$system/$helper")" == "$(cat "$backup/helper.sha256")" ]]; then
        rm "$system/$helper"
    fi
    echo "The stock PCB routing provider is installed."
    exit 0
fi

if [[ "$installed_sha" != "$original_sha" ]]; then
    [[ -f "$system/$helper" && -f "$backup/helper.sha256" &&
       "$(sha "$system/$helper")" == "$(cat "$backup/helper.sha256")" ]] ||
        fail "The routing helper is missing or has changed. Restore the original before reinstalling."
    echo "The Altium 26.12.2 routing guard is already installed."
    exit 0
fi

if [[ -e "$system/$helper" ]]; then
    [[ -f "$backup/helper.sha256" && "$(sha "$system/$helper")" == "$(cat "$backup/helper.sha256")" ]] ||
        fail "A different routing helper is already installed."
fi

wine_root="$(cd "$(dirname "$wine")/.." && pwd)"
compilers=("$wine_root"/share/wine/mono/wine-mono-*/lib/mono/4.5/mcs.exe)
compiler="${compilers[0]}"
cecil="${compiler%/4.5/mcs.exe}/gac/Mono.Cecil/0.11.1.0__0738eb9f132ed756/Mono.Cecil.dll"
[[ -f "$compiler" && -f "$cecil" ]] || fail "The bundled Wine Mono compiler and Mono.Cecil 0.11.1 are required."
stage="$(mktemp -d "$backup/build.XXXXXXXX")"
cp -p "$system/$provider" "$backup/$provider"
cp "$cecil" "$stage/Mono.Cecil.dll"
wine_path() { WINEPREFIX="$prefix" WINEDEBUG=-all "$wine" winepath -w "$1" | tr -d '\r'; }
(
    cd "$stage"
    export WINEPREFIX="$prefix" WINEDEBUG=-all
    "$wine" "$compiler" -nologo -target:library "-out:$helper" "$(wine_path "$sources/RoutingHandoffGuard.cs")"
    "$wine" "$compiler" -nologo -r:Mono.Cecil.dll -out:PatchRoutingProvider.exe \
        "$(wine_path "$sources/PatchRoutingProvider.cs")"
    "$wine" "$stage/PatchRoutingProvider.exe" "$(wine_path "$backup/$provider")" "$provider"
)
[[ -s "$stage/$provider" && -s "$stage/$helper" ]] || fail "The routing guard build produced incomplete files."
require_closed
[[ "$(sha "$system/$provider")" == "$original_sha" ]] || fail "The PCB provider changed during the build."
sha "$stage/$provider" > "$backup/provider.sha256"
sha "$stage/$helper" > "$backup/helper.sha256"
replace_file "$stage/$helper" "$helper"
replace_file "$stage/$provider" "$provider"
echo "Installed the Altium 26.12.2 routing guard."
