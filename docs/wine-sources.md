# Wine sources for the release

Release archives distribute replacement Wine modules, together with
the scripts and patches used to produce them. The complete upstream Wine
source and Wine Staging patchset are available alongside the binaries as
release assets. Wine is licensed under GNU LGPL 2.1 or later; the source
archive includes its AUTHORS, LICENSE and COPYING.LIB files.

| Input | Source | SHA-256 |
|---|---|---|
| Wine 11.16 | [wine-11.16.tar.xz](https://dl.winehq.org/wine/source/11.x/wine-11.16.tar.xz) | `c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f` |
| Wine Staging 11.16 | [v11.16 patchset](https://github.com/wine-staging/wine-staging/archive/refs/tags/v11.16.tar.gz), commit `f1936f02ba06b5012f89f75901944e8c2d26951c` | `626334d69853c683f558fcfaf66b4a2eefb3b9db5bccf16317fc897bcb514891` |
| Stock macOS bundle | [Gcenx wine-staging 11.16](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16) | `cd68f230c773a761b8a0423a08c51fbe49e89b6e52246f3866898d259a4988c6` |

`build-patched-wine.sh` contains the configure options, compiler selection,
module targets, patch order and binary transformations. It builds `winemac.so`,
`d2d1.dll`, `winhttp.dll`, `msado15.dll` (64- and 32-bit), the 32-bit `d3dx9_43.dll`, `kernelbase.dll`, `d3d9.dll`, `wined3d.dll`, and `wineserver`
from Wine 11.16 source. `winemac.so` also includes Wine Staging's no-flicker patch,
which is retained in `patches/0000`; `d3dx9_43.dll` includes Wine Staging's d3dx9 changes,
retained in `patches/0008`. The rebuilt `kernelbase.dll` retains Wine Staging's six
kernelbase patches in `patches/0011`, including its threadpool export forwarded to
the stock Staging `ntdll.dll`.
`d3d9.dll` retains the Staging SWVP changes in `0016`. `wineserver` retains the enabled
Staging server changes and protocol version 962 through `0014`; `0005` and `0013`
fix wakeup writes and signed DPI coordinates.
`0020` preserves queued panel-click ordering; `0021` opts AD17 windows into
sRGB backing stores for faster schematic panning.
`0023` adds parallel GDI copies in the Mac driver. Its private bitmap interface
is guarded by the exact stock 11.16 `win32u` UUID, function prologue and table
entries; an unknown module keeps ordinary copies. The stock `win32u.so` is
retained, including its FreeType, Vulkan and Staging support.
`wined3d.dll` retains the four enabled Staging wined3d patchsets in `0018`.
`0019` preserves AD17's dynamic ring upload hints across D3D9 and WineD3D;
`0022` queues immediate-draw streaming uploads for AD17.
`0029` prevents synchronous Cocoa callbacks from waiting on the main thread itself.
The 64-bit graphics modules keep the stock renderer.
`wow64cpu.dll` and `user32.dll` are transformed from the checksum-pinned stock
bundle by two Python patchers in `patches/`. The server is compiled from source. No other stock modules are
distributed in this repository's module archive.

To build the kit's replacements on an Apple Silicon Mac with Rosetta 2,
Xcode Command Line Tools and Homebrew:

```bash
bash altium-wine.sh setup
bash build-patched-wine.sh --export "$HOME/AltiumWine/build/modules-export"
```

The source-built modules use Wine's upstream source plus the listed kit
patches. For the Wine Staging baseline used by the stock bundle, unpack Wine
11.16 and apply `wine-staging-11.16/staging/patchinstall.py DESTDIR=/path/to/wine-11.16 --all`.
See the patchset's README and the [stock bundle's release notes](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16)
for its additional host-Vulkan portability patch. The stock bundle is fetched
separately by the installer.

The release module archive includes `PATCHES` and `SHA256SUMS`, recording the
hash of each distributed module. The release's top-level `SHA256SUMS` also
covers the source archives.


Patch `0023` combines the previously unpublished `0023`–`0028` sequence into its
final implementation: parallel bitmap copies, immutable pan snapshots with
pixel registration and coverage checks, modal input and tooltip fixes, and a
native Apple Silicon viewport-copy worker. Every CAD input and GDI write is
retained. Unknown Win32u builds and failed worker startup/IPC use ordinary Wine
copies. Mach replies are verified against the spawned worker's audit PID;
cached mappings are limited to four and can acquire write access when source
and destination roles reverse. The driver stops its own worker when unloaded.

The worker is built with the macOS SDK as `bin/altium-gdi-copy-arm64`. The
export contains thirteen files, all listed in `SHA256SUMS`. The original
Win32u, FreeType and Vulkan modules remain installed. Native copies defer
while the compositor preview is active. `AD17_NATIVE_GDI=0` and
`AD17_SMOOTH_SCHEMATIC_PAN=0` disable the respective paths before launching.
