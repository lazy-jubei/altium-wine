# config.sh - tunables for altium-wine.sh / build-patched-wine.sh
# Sourced by bash. Edit between rounds; re-run the main script to apply.

# Where Wine, the prefix and downloads live (NOT inside Downloads, it gets big).
WORK_ROOT="${ALTIUM_WINE_ROOT:-$HOME/AltiumWine}"

# Prebuilt Wine from github.com/Gcenx/macOS_Wine_builds (official WineHQ macOS builds).
#   WINE_FLAVOR: staging | devel
#   WINE_VERSION: latest | e.g. 11.16
WINE_FLAVOR="staging"
WINE_VERSION="11.16"
PINNED_WINE_VERSION="11.16"   # fallback if "latest" can't be resolved/downloaded

# Windows version reported to apps: win10 | win11
WINDOWS_VERSION="win10"

# winetricks verbs installed by `deps` (and on first default run).
# Candidates if logs point at them: dotnet48 msxml6 gdiplus vcrun2022
WINETRICKS_VERBS="corefonts"

# Extra DLL overrides, ';'-separated, e.g. "gdiplus=n,b;msxml6=n,b"
EXTRA_DLLOVERRIDES=""

# WINEDEBUG channels for logged runs.
WINEDEBUG_INSTALL="+timestamp,+pid,+tid,+seh,+loaddll,+process"
# Normal runs log errors only: +seh/+loaddll tracing slows Altium down noticeably
# (it logs every exception with a register dump). For debugging use e.g.
#   ALTIUM_WINEDEBUG="+timestamp,+pid,+tid,+seh,+loaddll" bash altium-wine.sh run
WINEDEBUG_RUN="${ALTIUM_WINEDEBUG:-fixme-all}"   # override per run: ALTIUM_WINEDEBUG=... altium-wine.sh run

# Use the bundle produced by build-patched-wine.sh (needed: the stock one crashes the
# installer and lacks the Altium fixes; see README). The patches are for staging 11.16 only.
USE_PATCHED_WINE=1

# Experimental, off: needs patches/0001 added to SOURCE_PATCHES in build-patched-wine.sh.
# Reports DWM composition as disabled so Delphi/VCL glass frames paint normally.
DWM_COMPOSITION_OFF=0

# DXVK and MoltenVK print a lot of info by default; keep only warnings/errors.
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-warn}"
export MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}"
