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
| FreeType headers 2.14.1 | [revision `526ec5c`](https://github.com/freetype/freetype/tree/526ec5c47b9ebccc4754c85ac0c0cdf7c85a5e9b) | `d24f53b60034dc5c48e90d122d432a8f04a05b9e0a98c8d8e49b4a759207ce2e` |
| Stock macOS bundle | [Gcenx wine-staging 11.16](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16) | `cd68f230c773a761b8a0423a08c51fbe49e89b6e52246f3866898d259a4988c6` |

`build-patched-wine.sh` contains the configure options, compiler selection,
module targets, patch order and binary transformations. It builds the matching `winemac.so` and `win32u.so`,
`d2d1.dll`, `dwrite.dll`, `winhttp.dll`, `gdiplus.dll` (64- and 32-bit), `msado15.dll` (64- and 32-bit), the 32-bit `d3dx9_43.dll`, `kernelbase.dll`, `d3d9.dll`, `wined3d.dll`, and `wineserver`
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
uses the source-built interface from `0051`, checking its version, size and
every consumed bitmap-prefix offset before using the reported copy tables.
The exact stock 11.16 UUID/prologue/table check remains as a fallback; unknown
modules keep ordinary copies. The rebuilt `win32u.so` retains FreeType and Vulkan using the stock bundle’s
`libfreetype.6.dylib` and `libvulkan.1.dylib`. The build downloads checksum-pinned
FreeType headers and checks that both backends are enabled.
`wined3d.dll` retains the four enabled Staging wined3d patchsets in `0018`.
`0019` preserves AD17's dynamic ring upload hints across D3D9 and WineD3D;
`0022` queues immediate-draw streaming uploads for AD17.
`0029` prevents synchronous Cocoa callbacks from waiting on the main thread itself.
`0030` corrects GDI+ font heights for the drawing surface DPI and pixel font units;
`0031` retains Staging’s GDI+ image-scaling optimizations;
`0032` corrects fractional measured text height and default vertical overhang.
`0033` exposes Wine’s containing window to macOS accessibility clients.
`0034` extends the floating-panel activation fix to modern Altium (`X2.EXE`).
`0035` replaces mouse interception with a guarded view-hide activation transfer,
including injected input, scripted closes and nested deactivation callbacks.
`0036` resolves multisampled Vulkan backbuffers before presentation and waits
for image acquisition at the first transfer use.
`0037` enables bounded Direct2D primitive caching and ordered solid drawing
batches by default; either optimization can be disabled with its environment switch.
`0042` caches scaled glyph bounds and bitmaps in the 64-bit DirectWrite module.
The stock `dwrite.so` handles the FreeType calls.
`0043` brings the clicked Altium document forward at its existing window level
when it remains active and another app covers it. Set `AD26_RESTORE_CLICKED_WINDOW_ORDER=0`
in `config.local.sh` to disable the check.
The standard Wine runtime keeps its stock 64-bit Direct3D modules. Patch `0045`
adds the DXMT window and surface bridge to the Mac driver. The optional Intel
runtime uses the same driver, wineserver and matching rebuilt Win32u module.
`0047` translates horizontal-only discrete Ctrl+Shift scroll events back to
vertical wheel events for Altium's PCB layer shortcut in Wine.
`0048` lets wineserver place its anonymous mapping files in a private,
executable-mapping-capable directory while retaining the normal fallback.
`0050` restores transparent GDI child painting over completed Metal frames. It
adds a paired Win32u/Mac-driver DC acquisition callback, so these two modules
must be installed together. Readback is asynchronous, limited to visible child
regions, and permits one copy in flight. It also prevents DXMT layout updates
from activating an inactive document surface. See the graphics details in
[technical-notes.md](technical-notes.md).
`0051` preserves the existing parallel/native copy and schematic preview paths
with the rebuilt Win32u. It reports the source-defined bitmap layout and copy
table addresses instead of relying on link addresses from the stock binary.
`0052` retains the stock bundle’s [host Vulkan portability patch](https://gitlab.winehq.org/wine/wine/-/merge_requests/11538)
by Dean M Greer. It enables portability enumeration for the host Vulkan loader;
without it the rebuilt Win32u cannot discover MoltenVK devices.
`0053` retains the enabled Wine Staging Win32u patches for keyboard-layout
enumeration, window-message ordering, recursive activation and transformed text.
The disabled mouse-message patch is excluded.
`0055` keeps the outgoing Metal client visible during a canvas transition until
the replacement presents or software painting covers the old viewport. The Mac
driver and Win32u are built together so Win32u can report the opaque paint.
`0056` preserves the opacity of Windows color cursor and icon edges in Core
Graphics by marking the bitmap produced by `DrawIconEx` as premultiplied.
`wow64cpu.dll` and `user32.dll` are transformed from the checksum-pinned stock
bundle by two Python patchers in `patches/`. The server is compiled from source. No other stock modules are
distributed in this repository's module archive.

To build the kit's replacements on an Apple Silicon Mac with Rosetta 2,
Xcode Command Line Tools and MacPorts (bison comes from it):

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
export lists every distributed module in `SHA256SUMS`. FreeType and Vulkan
libraries remain supplied by the stock bundle. Native copies defer
while the compositor preview is active. `AD17_NATIVE_GDI=0` and
`AD17_SMOOTH_SCHEMATIC_PAN=0` disable the respective paths before launching.

## Optional DXMT module sources

The x86-64 DXMT modules are based on [DXMT commit
`0df86108348bab2aaa5c4610a5eb63a9de9047ac`](https://github.com/3Shain/dxmt/tree/0df86108348bab2aaa5c4610a5eb63a9de9047ac)
and its [upstream CI build](https://github.com/3Shain/dxmt/actions/runs/42785253423).
The release includes the exact DXMT source archive and the required
[DirectX headers](https://github.com/misyltoad/mingw-directx-headers/tree/9df86f2341616ef1888ae59919feaa6d4fad693d).
DXMT's license files are included with the modules. The CI workflow in the
source archive pins its LLVM and MinGW build inputs.

`patches/dxmt-gdi-surfaces.patch` preserves the GDI-compatible swap-chain
backbuffer requested by Direct2D and implements the surface's GDI read and
write operations. `tools/dxmt-metal-init.m` initializes Metal early and
retries the Altium PCB grid pipeline if the first attempt fails. DXMT's shader
cache is disabled for this launcher because stale shaders can blank the 2D
canvas on the tested Radeon.

With Meson, Ninja, an x86-64 LLVM-MinGW toolchain on `PATH`, Xcode Command Line
Tools and the Wine build directory, reproduce the DXMT modules using:

```bash
wine_build="$HOME/AltiumWine/build/obj-wine-11.16"
bash tools/build-dxmt-modules.sh ./unpacked-release/modules/dxmt ./release-sources \
  "$wine_build" ./modules-export/dxmt
```

The first input can also be the upstream CI ZIP. The build checks its input digests. It reuses only the command shader library
from the pinned CI build and builds the replacement `d3d11.dll` and Metal
initializer from source. The other DXMT binaries come from that same build.
