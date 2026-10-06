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

# AD17's CefSharp Home page/reports: avoid a spinning Chromium GPU process.
# This does not change CAD rendering. Set to 0 to test Chromium's GPU path.
AD17_CEF_SOFTWARE_RENDERING="${AD17_CEF_SOFTWARE_RENDERING:-1}"

# AD17 dynamic PCB buffer uploads: queue partial writes instead of mapping each one.
AD17_FAST_UPLOADS="${AD17_FAST_UPLOADS:-1}"
# Preserve dynamic-ring hints and map only the changed OpenGL upload range.
AD17_FAST_UPLOAD_HINTS="${AD17_FAST_UPLOAD_HINTS:-1}"
# Queue immediate-draw vertex/index data with the dynamic ring uploads.
AD17_FAST_UP_DRAWS="${AD17_FAST_UP_DRAWS:-1}"
# Match the GDI image color space to avoid a full Retina surface conversion.
AD17_SRGB_WINDOWS="${AD17_SRGB_WINDOWS:-1}"
# Split large GDI copies into independent rows/columns on the verified Wine build.
AD17_PARALLEL_GDI="${AD17_PARALLEL_GDI:-1}"
AD17_GDI_WORKERS="${AD17_GDI_WORKERS:-2}"
# Smooth right-button schematic pans with native compositor interpolation.
AD17_SMOOTH_SCHEMATIC_PAN="${AD17_SMOOTH_SCHEMATIC_PAN:-1}"

# Experimental, off: needs patches/0001 added to SOURCE_PATCHES in build-patched-wine.sh.
# Reports DWM composition as disabled so Delphi/VCL glass frames paint normally.
DWM_COMPOSITION_OFF=0

# DXVK and MoltenVK print a lot of info by default; keep only warnings/errors.
export DXVK_LOG_LEVEL="${DXVK_LOG_LEVEL:-warn}"
export MVK_CONFIG_LOG_LEVEL="${MVK_CONFIG_LOG_LEVEL:-1}"

# Native Apple Silicon worker for complete schematic viewport copies.
AD17_NATIVE_GDI="${AD17_NATIVE_GDI:-1}"
AD17_NATIVE_GDI_WORKERS="${AD17_NATIVE_GDI_WORKERS:-2}"

# Match AD26's UI backing color space without changing its GPU canvas.
AD26_SRGB_WINDOWS="${AD26_SRGB_WINDOWS:-1}"
