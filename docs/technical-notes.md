# Technical notes

Run the commands below from the repository root.

## Making a release

```bash
bash build-patched-wine.sh --export ~/AltiumWine/build/modules-export   # 13 changed files + SHA256SUMS
bash make-release.sh --version v1.0.0 \
     --url https://github.com/lazy-jubei/altium-wine/releases/download/v1.0.0 \
     --modules ~/AltiumWine/build/modules-export
```

`make-release.sh` writes `dist/v1.0.0/` locally:

- `install.sh`, with the URL and the two archive checksums filled in;
- `altium-wine-kit-v1.0.0.tar.gz`;
- `altium-wine-modules-v1.0.0.tar.gz`;
- `SHA256SUMS`.

Uploading those files to the URL is a separate step. Include the source archives described in [docs/wine-sources.md](wine-sources.md), and add their hashes to `SHA256SUMS`. Then `curl -fsSL <url>/install.sh | bash` works.

To test before uploading, serve `dist/` locally and point a throwaway `--root` at it:

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory dist/v0.9-test
curl -fsSL http://127.0.0.1:8765/install.sh | bash -s -- --root ~/AWT --skip-altium --yes
```

The test release must be built with `--url http://127.0.0.1:8765`.

## Commands

| Command | Purpose |
|---|---|
| *(none)* | Runs setup and deps if they haven't run yet, then the installer |
| `setup [--force-wine]` | Downloads Wine, builds the patched bundle if missing, and creates or refreshes the prefix. Refuses while Altium is running. |
| `deps [verbs]` | Installs winetricks verbs (default: `WINETRICKS_VERBS`) |
| `install [DIR]` | Runs `Installer.Exe` from `DIR` (default: the folder that contains `wine-kit`) |
| `run` | Installs or updates DXVK next to `X2.EXE`, then starts Altium |
| `hang-dump` | Writes backtraces of every Wine thread. Under Rosetta this can crash 32-bit processes in the prefix. |
| `doctor` | Writes system, Wine and prefix diagnostics |
| `wine <prog>` | Runs a program in the prefix, e.g. `wine winecfg` or `wine regedit` |
| `launcher [DIR]` | Creates `Altium Designer (Wine).app` (default in `~/Applications`) |
| `reset` | Deletes the prefix and keeps the downloaded Wine |
| `uninstall` | Deletes the whole install folder (Wine, prefix, Altium, projects stored in the prefix) and the launcher, after you type `delete` |

Logs land in `logs/`. `LATEST-summary.txt` is the short version.

Environment variables:

| Variable | Effect |
|---|---|
| `ALTIUM_WINE_ROOT` | Where Wine, the prefix and downloads go (default `~/AltiumWine`). Keep it short: Wine's prefix creation crashed under a 160-character path, so `setup` refuses prefix paths over 80 characters. |
| `PATCHED_MODULES_DIR` | Prebuilt `winemac.so`, `d2d1.dll` and `winhttp.dll` (+ `SHA256SUMS`) for the first `setup`, so no compiler is needed. |
| `ALTIUM_WINEDEBUG` | `WINEDEBUG` channels for `run`. |
| `KILL_WEBVIEW2=0` | Turns off the WebView2 watchdog. |
| `WINE_D2D_LAZY_STATE=0` | Turns off the Direct2D state-caching part of patch 0003. |

## Wine patches and settings

### Wine fixes (`~/AltiumWine/wine-patched`)

`build-patched-wine.sh` copies the stock bundle and changes thirteen files. Everything else stays byte-identical to the tested Gcenx build.

| Problem | Fix | File changed |
|---|---|---|
| Installer crashes after about 5 s (`exception outside of stack limits`, `wow64cpu+0x1135`, exit 40). Rosetta 2 runs Wine's 64-bit syscall entry in 32-bit mode after Delphi writes code into an already-executed page. | `patches/wow64cpu-rosetta-trampoline.py`: both 32→64-bit thunks go through a trampoline that detects the CPU mode and retries the switch. | `wow64cpu.dll` (binary patch) |
| Altium Designer 17 (32-bit `DXP.EXE`) crashes about 40 s in with "Exception frame is not in stack limits", at an address whose low half is a 32-bit return address. Its startup walks the global atom table with about 16,000 syscalls; eventually Rosetta doesn't switch back to 32-bit mode on the `ljmp` that returns from a syscall, and the first 32-bit `ret` pops 8 bytes. | Same patcher: the two return-to-32-bit sites build an `iretq` frame and return with `iretq`, as wow64cpu's full-context return already does. A mode-detecting 32-bit landing pad doesn't work: Rosetta faults on a far transfer into 32-bit mode at a page that also holds 64-bit code. | `wow64cpu.dll` (binary patch) |
| Altium Designer 17 crashes at startup: "Access violation … in module 'IntegratedLibrary.DLL' … Failed to initialize application". Its library server (Delphi ADO components) sets `Command.CommandTimeout`, reads `Parameter.NumericScale`/`Precision`, sets `Command.Prepared`; each was a Wine stub returning E_NOTIMPL, Delphi raised, the server's cleanup freed an object that later code still used. | `patches/0006-msado15-command-parameter-properties.patch`: those and the other simple Command/Parameter properties are now stored values, and `Parameters.Item` works by index or name. | `msado15.dll` (64- and 32-bit) |
| "wineserver crashed", after which everything else in the prefix freezes, when a Wine process ends while others run (closing a second Altium window, a `kill`). An upstream bug (still in master): `wake_up()` walks an object's wait queue; waking a waiter whose process already died hits EPIPE, `send_thread_wakeup()` calls `kill_thread()` on the spot, and destroying that process's handles frees the object being walked (the sync of its message queue). Found with an AddressSanitizer build of the same source: heap-use-after-free in `wake_up`. | `patches/0005-server-wakeup-epipe.patch`: on EPIPE just report the failure; the main loop kills the thread a moment later when it sees the closed request pipe.  | `wineserver` (source build, re-signed ad hoc) |
| Opening any menu raises `External exception C06D007F` and the modal error freezes Altium. `user32!InheritWindowMonitor` is missing. | `patches/pe-add-stub-exports.py`: exports it as a stub that returns TRUE. | `user32.dll` (binary patch) |
| Cloning an Altium 365 project fails with "Git Error: failed to receive response". Wine waits at most 21 s for response headers; the Git server can take longer. | `patches/0004-winhttp-infinite-receive-timeout.patch`: requests whose app asked for an infinite receive timeout (libgit2 does) wait for headers without the 21 s cap. Other apps are unchanged. | `winhttp.dll` |
| After switching document tabs, the old view stays on top. Pop-out panels hide under the 3D view. Each DXVK/Metal view is a Cocoa layer above the whole window that ignored Win32 visibility and z-order. | `patches/0002-winemac-clip-client-surfaces.patch`: clips each view to its window's visible region (CAShapeLayer mask) and hides it when nothing is visible. | `winemac.so` |
| A modal dialog opens or ends up behind its blocked main window, so the app looks frozen (Altium 17's "Account Sign In", an error dialog that froze Altium 26's menus). Delphi owns the main form and all dialogs by a hidden application window, so nothing keeps the dialog on top, and the Mac driver didn't do what Windows does when you click a window blocked by a modal dialog. | `patches/0007-winemac-activate-blocking-popup.patch`: a click on a disabled window activates its owner's last active popup (or, when the main form isn't owned by the application window as in Altium 17, the thread's foreground window), and when the app is activated its active window goes back on top. | `winemac.so` |
| Altium Designer 17's PCB 3D view draws the board and every 3D body black (the 2D view and the shadows are fine). The 3D effect sets its lights (`SCSceneLights`, an array of two structures of five float4) with `ID3DXEffect::SetRawValue`; Wine's d3dx9 returned E_NOTIMPL for an array of structures (`Unhandled structure member parameter class D3DXPC_STRUCT`, about 3,000 times a session), so the lights' pixel-shader constants stayed zero. | `patches/0009-d3dx9-effect-setrawvalue-struct-arrays.patch`: set the array's elements one by one. It sits on `patches/0008-d3dx9-staging-sync.patch`, which brings plain Wine 11.16's d3dx9 up to the code in the stock wine-staging bundle (it already has SetRawValue for vectors and structures, `D3DXComputeTangent` and more). | `d3dx9_43.dll` (32-bit) |
| AD17 stalls while loading STEP models after AltiumMS exits with `EWriteError: Stream write error`. It writes synchronously to an overlapped duplex pipe; another read can signal the shared handle before the write completes, returning `ERROR_IO_PENDING` to Delphi's stream writer. | `patches/0010-kernelbase-altiumms-pipe-write-event.patch`: use a private completion event for NULL-overlapped pipe writes in `AltiumMS.exe`. Other applications and ordinary overlapped writes retain their existing behavior. | `kernelbase.dll` (32-bit) |
| Schematic scrolling lags by seconds. Wine's Direct2D swapped the whole D3D11 state twice per primitive (about 8,000 per redraw), re-triangulated every glyph each frame and made new GPU buffers for every shape. | `patches/0003-d2d1-fast-redraw.patch`: keeps D2D state bound between draws, caches glyph geometry per device and buffers per geometry, and fast-paths FillRectangle. `WINE_D2D_LAZY_STATE=0` turns the state part off. | `d2d1.dll` |

`winemac.so` is built with `patches/0000-staging-winemac-no-flicker.patch`, which is wine-staging's own patch and is in the stock build too, so nothing from staging is lost.

Verification:

- Wine's d2d1 conformance tests (5,553 checks) give identical results with and without 0003, both single- and multi-threaded. Eleven test groups that crash under DXVK with stock Wine too (DC, HWND and WIC targets) were skipped.
- The winhttp notification tests are unchanged.
- A local server that delays headers by 25 s fails at 21.0 s with stock winhttp and succeeds with 0004.
- Server crash: with Altium 17 running, SIGTERM to another process in the prefix crashed the stock server on the first try; with the patch it survived 5 of 5 rounds (and an AddressSanitizer build reported nothing).
- Model-server writes: `diagnostics/model-pipe-write.c` reproduces error 997 with the original DLL. With `0010`, NULL-overlapped and ordinary overlapped modes both transfer and verify 3,932,160 bytes. The Music board then loaded and rendered in 3D without a new entry in Altium's `mc.log`.

### Prefix settings (`extra.reg`, imported by `setup`)

- **Direct3D 11 through DXVK-macOS** (v1.10.3-20230507-repack, github.com/Gcenx/DXVK-macOS). Wine's own Direct3D can't reach the feature level Altium's editors need on macOS. Without it you get "DX initialization failed" and *Control "View…" has no parent window*. `run` copies `d3d11.dll` and `d3d10core.dll` next to `X2.EXE`, and a per-app override limits them to Altium.
- **Retina:** `RetinaMode=y` plus 192 DPI (200%). Without it, Wine renders at half resolution and text is jagged.
- **Fonts:** Segoe UI is mapped to Arial (from corefonts). The fallback font drew `-` as a box.
- **WPF dialogs** had black areas. `Avalon.Graphics\DisableHWAcceleration=1` renders them in software.
- **WebView2** (only drives the Home Page): its GPU process dies under Wine. The `AdditionalBrowserArguments` policy for `X2.EXE` runs it without GPU and without Chromium's sandbox. Wine doesn't enforce the Windows primitives that sandbox relies on, so the sandbox can't work here anyway. It only loads Altium's own pages.

### WebView2 watchdog

WebView2's `VideoCaptureThread` spins forever under Wine and floods `wineserver`, which cut PCB panning from about 130 fps to about 50. `run` ends Altium's WebView2 browser 20 s after it starts. Blocking it from starting instead makes Altium show "File not found (0x80070002)". `KILL_WEBVIEW2=0` turns the watchdog off.

### AD17 CefSharp browser

AD17 uses CefSharp instead of WebView2. Its Chromium GPU helper can spin at roughly 150% CPU and leave the Home page and HTML reports blank. For `DXP.EXE`, `run` now supplies `--disable-gpu --disable-gpu-compositing`; both views render in testing and helpers stay at low CPU usage. PCB Direct3D rendering still works. `AD17_CEF_SOFTWARE_RENDERING=0` opts out. Some current websites use JavaScript features absent from AD17's old Chromium, so these flags cannot restore every website feature.

## Performance

Altium 26.10.1, measured with MoltenVK frame statistics on an M4:

| | Before | Now |
|---|---|---|
| PCB pan | about 2 fps | about 48 fps (Retina), about 130 fps (Retina off) |
| Schematic scroll | about 230 ms per wheel notch, seconds of backlog | about 85 ms per notch, about 40 fps |

- **Speed over sharpness:** set `"RetinaMode"="n"` and `"LogPixels"=dword:00000060` in `extra.reg`, then run `setup`.
- **Debug logging** is errors-only by default. For a traced run: `ALTIUM_WINEDEBUG="+timestamp,+pid,+tid,+seh,+loaddll" bash altium-wine.sh run`.
- **Measuring:** run `MVK_CONFIG_PERFORMANCE_TRACKING=1 MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT=30 MVK_CONFIG_LOG_LEVEL=3 bash altium-wine.sh run`, then grep the log for `avg FPS`. DXVK's HUD doesn't render on MoltenVK.

### Altium 17

AD17 uses Direct3D 9 for PCB rendering. It performs roughly 1,600 small dynamic
vertex-buffer locks per frame on a 2 MiB ring. The synchronous map/unmap round
trips cost about 230 ms per frame under WoW64/Rosetta. Patch `0015` queues copies
of the written ranges, reducing measured lock/unlock time to about 2 ms while
keeping update/draw ordering. It handles partial and nested vertex/index writes;
static/managed buffers retain Wine's normal path. `0016` preserves the Staging
D3D9 baseline. The launcher enables this only for DXP; `AD17_FAST_UPLOADS=0` opts out.

A final 24-step 3D rotation trial took 32.0 seconds with ordinary uploads and
19.8 seconds with queued uploads, with profiling removed and `SampleCount=0`
for both runs. An earlier traced trial measured 35.9 versus 22.7 seconds and
present rates around 2.4–2.6 versus 3.9–4.2 fps. These are AD17 results on one
dense board, not the AD26 rates above.
Remaining draw/command-stream work still limits interactivity. Retina resolution,
CSMT and antialiasing defaults are unchanged.

Patch `0019` retains DISCARD/NOOVERWRITE hints through the queued uploads and
maps only the changed OpenGL range. This avoids implicit GPU waits in
`glBufferSubData` without mapping the whole ring. With the same board, camera,
viewport and `SampleCount=0,csmt=1`, a 24-step rotation took 20.1 seconds with
hints disabled and 14.7/14.5 seconds with them enabled (about 27% less wait).
A whole-buffer mapping trial was slower at 27.3 seconds and was discarded.
The launcher enables the range path for AD17; `AD17_FAST_UPLOAD_HINTS=0` retains
the previous queued path. GPU readback verifies partial discards at nonzero
offsets, nested writes and earlier draws after ring reuse. `0018` retains the
four enabled Staging WineD3D patchsets when rebuilding the 32-bit renderer.

On one dense FPGA schematic, 24 full refreshes took 10.6 seconds with GDI+ text
and 8.0 seconds with GDI text, with tracing disabled in both runs. The tested
prefix now has `RenderTextUsingGDIP=0` under its Altium `SCH\Schematic Preferences`
key. Its previous key was exported before the change. Other imported preferences
are retained; the kit does not overwrite this preference on every launch.

Patch `0021` matches Cocoa window backing stores to Wine's sRGB GDI images.
Profiling schematic panning showed the Cocoa main thread spending most of its
time converting the entire Retina image for each update. Matching the color
space avoids that conversion while retaining color management and resolution.
The same dense schematic pan rose from 14.7 to 26.4 fps. These count changed
content frames in a cropped window capture during an 18-second steady section
of a 20-second right drag; the cursor and status bars are excluded. The launcher
enables this for AD17; `AD17_SRGB_WINDOWS=0` restores the previous backing store.

Before the immediate-upload and transparency changes below, a dense Music PCB
panned at 6.9 fps in 3D in the full Retina window. Disabling antialiasing
reached 7.4 fps, disabling the command-stream thread dropped to 5.1 fps, and
native Microsoft D3DX gave 6.8 fps. A 1920×1080 window gave 7.7 fps. These trials
were discarded; normal graphics settings are retained. A temporary API profiler
found roughly 50,000 render-state calls per frame plus texture unmap waits.
The setter timings included substantial clock-probe overhead and do not isolate
a bottleneck. The device is multithreaded, so its state locks are retained.
The profiler was removed from the installed build.

Patch `0022` queues owned copies of immediate-draw vertex/index data instead of
mapping the streaming buffer synchronously. A same-instance Music-board pan at
full Retina resolution measured **6.7 fps off and 8.2 fps on**, about 21% faster.
A repeat with the fast path gives 8.1 fps.
Alignment, ring wraps and upload/draw ordering
are retained; GPU readback tests cover caller data lifetime, varying strides,
16/32-bit indices, buffer growth, state cleanup and Reset. The launcher enables
this for AD17; `AD17_FAST_UP_DRAWS=0` restores the old path. A separate CPU texture
map trial was discarded. No profiling code is included in the final modules.

For faster AD17 3D rendering, turn off **Use Ordered Blending in 3D** under
**Preferences → PCB Editor → Display**. The same running Music board measured
**13.9 fps**, **8.2 fps** with the option restored, then **13.8 fps** with it off
again. Retina resolution, 8× antialiasing, shadows and component models remain
enabled. A normal-launch restart with the verified renderer gives **14.0 fps**.
This selects simpler transparency rendering, so overlapping translucent
surfaces can look different. The tested AD17 prefix retains this preference;
the launcher does not overwrite it. Re-enable the checkbox to restore the
previous rendering mode.

A further CPU texture-map and staging-upload snapshot trial passed ordering,
dirty-region, source-lifetime, mip, DC, threading and Reset checks, but measured
7.7 fps against 8.4 fps with the trial disabled in the same instance. It was
discarded; the installed renderer keeps patch `0022` as its latest change.

Patch `0013` fixes unsigned arithmetic in the server's DPI scaling: negative
window coordinates became huge positive values in cross-process queries. `0014`
retains the enabled Staging server patches and protocol version 962 so the
rebuilt server remains compatible with the stock client modules.

Patch `0012` restores separately owned modal windows after Cocoa activation,
after the native window order has been restored. AD17's error dialog remains
visible above its separately owned main form when switching back from Finder.

Patch `0017` transfers activation before the Close mouse-up on an active AD17
floating panel. Otherwise Delphi deactivates its embedded view after it has been
detached, raising *Control "View…" has no parent window* on the next viewport
click. Close/click tests pass for Sheet, SCH Inspector, SCH List and Storage
Manager over a PCB. Ordinary Open dialogs also retain their ordering after
switching applications.

Patch `0020` covers rapid clicks: the native Close release can arrive before
Windows handles the panel's earlier mouse messages. It drains those panel
messages before transferring activation, so a delayed click cannot reactivate
the detached view. Rapid, held and inactive-panel Close tests pass; other input
paths retain their normal handling.

## Building the patched Wine

```bash
bash build-patched-wine.sh                      # build the Wine replacements from 11.16 source + patches/
bash build-patched-wine.sh --modules DIR        # use prebuilt winemac.so/d2d1.dll/winhttp.dll (checks DIR/SHA256SUMS)
bash build-patched-wine.sh --export DIR         # build, then copy the modules + SHA256SUMS to DIR
bash build-patched-wine.sh --clean              # delete the source and object trees
```

- **Sources:** the Wine 11.16 tarball from dl.winehq.org (checksum-verified). It's unpacked fresh and patched each run.
- **Compilers:** the host side is built with Apple's clang under Rosetta, and the PE side with llvm-mingw (downloaded to `~/AltiumWine/tools`).
- **Swap:** the new bundle is assembled next to the old one and swapped in. The script refuses while Wine from that bundle is running.
- **Manifest:** `wine-patched/PATCHES` lists the sha256 of every changed file.

The binary patchers check the exact bytes they patch and refuse any other Wine build. The patches target wine-staging 11.16 only: moving to another Wine version means re-checking the two binary patches and rebasing 0002–0004.

## Known limits

- **AD17 viewport:** dense boards remain slow despite faster uploads; the remaining draw/command-stream work still limits frame rate.
- **Geometry shaders:** MoltenVK has none, so DXVK can't compile Altium pipelines that use them ("Failed to compile pipeline" with a `gs` stage), and those draws are skipped. No missing graphics have been noticed so far.
- **Home Page (AD18+):** blank, see WebView2 above. AD17's Home page and HTML reports render with its CefSharp software-rendering flags.
- **Stale clip:** a document view that stops presenting keeps its last clip until its window moves, resizes or changes z-order. Not seen in practice.
- **Trampoline retry:** the wow64cpu trampoline retries the mode switch until it succeeds, so if Rosetta kept failing it the thread would spin instead of crashing. Not seen in testing.
- **Untried:** 32-bit Windows apps other than the Altium installer.

## Tried and dropped

- Wine 11.18 instead of 11.16, which has the same crash.
- A Wine virtual desktop, which the Mac driver ignores.
- Wine's Vulkan renderer for wined3d, which is still below the needed feature level.
- A direct far jump in place of the trampoline.
- Blocking WebView2.
- DXMT, which DXVK made unnecessary.

## Files

- `install.sh`: the installer (`curl | bash` from a release, or run from this folder)
- `make-release.sh`: packages a release for `install.sh`
- `altium-wine.sh`: the main script
- `config.sh`: settings. `config.local.sh` holds machine-specific overrides; `install.sh` writes it and updates keep it.
- `build-patched-wine.sh`: builds `~/AltiumWine/wine-patched`
- `patches/`: the Wine source patches (`0000`, `0002`–`0004`) and the binary patchers (`*.py`). `0001-dwmapi-…` is an unused experiment, not built.
- `extra.reg`: registry settings imported by `setup`
- `tools/exe-icon.py`: extracts Altium's icon for the launcher
- `logs/`: per-run logs; start with `LATEST-summary.txt`

## License notes

- **Kit scripts and original patches:** GNU LGPL 2.1 or later; see [LICENSE](../LICENSE).
- **Wine:** LGPL 2.1+. Existing Wine and Wine Staging copyrights are retained; see [NOTICE](../NOTICE).
- **Redistribution:** releases include the kit patches, Wine 11.16 source and Wine Staging 11.16 patchset. Build details and upstream source checksums are in [docs/wine-sources.md](wine-sources.md).
- **DXVK:** zlib license.
- **Altium Designer and its installer:** not redistributable. Each user needs their own copy and license.
### AD17 schematic panning

Patch `0023-winemac-schematic-performance.patch` combines parallel GDI copies,
native viewport copies, safe pan compositing and the modal/tooltip input fixes.
It replaces the unpublished `0023`–`0028` development sequence.

The 2560×1355 Retina test on an M4 measured **27.7 fps with ordinary copies**
and **33.3 fps with parallel copies**. Two workers perform as well as four;
eight are slower. With smoothing disabled, native Apple Silicon viewport copies
measured **31.89 fps off / 37.44 fps on**. These are changed CAD content frames
from the central 18 seconds of a 20-second pan, excluding cursor/status updates.

Large 32-bit SRCCOPY operations use independent rows or overlap-safe vertical
columns. Diagonal overlaps and other raster operations keep Wine's original
path. A guarded hook checks the stock Wine 11.16 Win32u UUID, function prologue
and copy-table pointers; an unknown build falls back. Win32u itself is unchanged.

The preview snapshots immutable pixels when GDI completes a viewport copy,
verifies translation against CAD edges, and keeps three drawings per gesture.
It smooths only when the cached drawings cover the entire animation sweep.
Unseen corners, ambiguous pixels and changed drawings show complete CAD frames.
Three unsafe diagonal transitions disable caching for the remaining drag.
Editing, zoom, modifiers, resize, modal dialogs and release cancel/settle it.
No input or GDI write is suppressed.

The final edge-safe implementation measured **47.89 visible fps** (862/18 s) with
120-Hz input/capture. Earlier 96–99 fps measurements used the old predictor,
which exposed seams and is removed. Enabling native transfers during previews
measured 43.94 fps and was discarded. Native copies still defer during preview.
60 complete CAD redraws/s has not been reached on this AD17 test sheet.

Fast 600×300-point figure-eights with a 1.2-second period show clean captured
corners and reversals. Held/released and released/refreshed comparisons show
zero pixel shift. Pixel tests cover cropping, negative strides, immutable
ownership, translation, blank/changed/periodic drawing rejection, plus 5,000
random coverage cases. GDI readback covers padding, clips, both orientations,
raster operations, nine overlap directions and text. Native-copy tests cover
reversed source/destination roles and address reuse with a new VM object.

The input fixes keep properties dialogs in front when clicking a disabled
canvas, retain nested dialog ordering, and make AD17's `TGoldenHintForm`
nonactivating and mouse-transparent. Component edits, undo/redo, wire and net
label placement, copy/paste/move/delete, save/reopen, hover, fit and resize were
checked on disposable documents.

Launcher controls (defaults shown): `AD17_PARALLEL_GDI=1`, `AD17_GDI_WORKERS=2`,
`AD17_NATIVE_GDI=1`, `AD17_NATIVE_GDI_WORKERS=2`, `AD17_SMOOTH_SCHEMATIC_PAN=1`.
Set a feature to `0` before launching to disable it. `ALTIUM_PAN_STATS=1` logs
per-gesture compositor counts. [Reproduction helpers](../diagnostics/README.md).

GPU bitmap copies, contiguous/SIMD/prefetch copies, native scrolling, unbuffered
painting, hidden grids, direct GDI dispatch, display-link updates, higher thread
priority and suppressed draws were tried and discarded. Reduced viewport sizes
can be faster but are not comparable to the full Retina measurement above.
