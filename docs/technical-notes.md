# Technical notes

Run the commands below from the repository root.

## Making a release

```bash
bash build-patched-wine.sh --export ~/AltiumWine/build/modules-export   # 5 changed files + SHA256SUMS
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

`build-patched-wine.sh` copies the stock bundle and changes five files. Everything else stays byte-identical to the tested Gcenx build.

| Problem | Fix | File changed |
|---|---|---|
| Installer crashes after about 5 s (`exception outside of stack limits`, `wow64cpu+0x1135`, exit 40). Rosetta 2 runs Wine's 64-bit syscall entry in 32-bit mode after Delphi writes code into an already-executed page. | `patches/wow64cpu-rosetta-trampoline.py`: both 32→64-bit thunks go through a trampoline that detects the CPU mode and retries the switch. | `wow64cpu.dll` (binary patch) |
| Opening any menu raises `External exception C06D007F` and the modal error freezes Altium. `user32!InheritWindowMonitor` is missing. | `patches/pe-add-stub-exports.py`: exports it as a stub that returns TRUE. | `user32.dll` (binary patch) |
| Cloning an Altium 365 project fails with "Git Error: failed to receive response". Wine waits at most 21 s for response headers; the Git server can take longer. | `patches/0004-winhttp-infinite-receive-timeout.patch`: requests whose app asked for an infinite receive timeout (libgit2 does) wait for headers without the 21 s cap. Other apps are unchanged. | `winhttp.dll` |
| After switching document tabs, the old view stays on top. Pop-out panels hide under the 3D view. Each DXVK/Metal view is a Cocoa layer above the whole window that ignored Win32 visibility and z-order. | `patches/0002-winemac-clip-client-surfaces.patch`: clips each view to its window's visible region (CAShapeLayer mask) and hides it when nothing is visible. | `winemac.so` |
| Schematic scrolling lags by seconds. Wine's Direct2D swapped the whole D3D11 state twice per primitive (about 8,000 per redraw), re-triangulated every glyph each frame and made new GPU buffers for every shape. | `patches/0003-d2d1-fast-redraw.patch`: keeps D2D state bound between draws, caches glyph geometry per device and buffers per geometry, and fast-paths FillRectangle. `WINE_D2D_LAZY_STATE=0` turns the state part off. | `d2d1.dll` |

`winemac.so` is built with `patches/0000-staging-winemac-no-flicker.patch`, which is wine-staging's own patch and is in the stock build too, so nothing from staging is lost.

Verification:

- Wine's d2d1 conformance tests (5,553 checks) give identical results with and without 0003, both single- and multi-threaded. Eleven test groups that crash under DXVK with stock Wine too (DC, HWND and WIC targets) were skipped.
- The winhttp notification tests are unchanged.
- A local server that delays headers by 25 s fails at 21.0 s with stock winhttp and succeeds with 0004.

### Prefix settings (`extra.reg`, imported by `setup`)

- **Direct3D 11 through DXVK-macOS** (v1.10.3-20230507-repack, github.com/Gcenx/DXVK-macOS). Wine's own Direct3D can't reach the feature level Altium's editors need on macOS. Without it you get "DX initialization failed" and *Control "View…" has no parent window*. `run` copies `d3d11.dll` and `d3d10core.dll` next to `X2.EXE`, and a per-app override limits them to Altium.
- **Retina:** `RetinaMode=y` plus 192 DPI (200%). Without it, Wine renders at half resolution and text is jagged.
- **Fonts:** Segoe UI is mapped to Arial (from corefonts). The fallback font drew `-` as a box.
- **WPF dialogs** had black areas. `Avalon.Graphics\DisableHWAcceleration=1` renders them in software.
- **WebView2** (only drives the Home Page): its GPU process dies under Wine. The `AdditionalBrowserArguments` policy for `X2.EXE` runs it without GPU and without Chromium's sandbox. Wine doesn't enforce the Windows primitives that sandbox relies on, so the sandbox can't work here anyway. It only loads Altium's own pages.

### WebView2 watchdog

WebView2's `VideoCaptureThread` spins forever under Wine and floods `wineserver`, which cut PCB panning from about 130 fps to about 50. `run` ends Altium's WebView2 browser 20 s after it starts. Blocking it from starting instead makes Altium show "File not found (0x80070002)". `KILL_WEBVIEW2=0` turns the watchdog off.

## Performance

Measured with MoltenVK frame statistics on an M4:

| | Before | Now |
|---|---|---|
| PCB pan | about 2 fps | about 48 fps (Retina), about 130 fps (Retina off) |
| Schematic scroll | about 230 ms per wheel notch, seconds of backlog | about 85 ms per notch, about 40 fps |

- **Speed over sharpness:** set `"RetinaMode"="n"` and `"LogPixels"=dword:00000060` in `extra.reg`, then run `setup`.
- **Debug logging** is errors-only by default. For a traced run: `ALTIUM_WINEDEBUG="+timestamp,+pid,+tid,+seh,+loaddll" bash altium-wine.sh run`.
- **Measuring:** run `MVK_CONFIG_PERFORMANCE_TRACKING=1 MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT=30 MVK_CONFIG_LOG_LEVEL=3 bash altium-wine.sh run`, then grep the log for `avg FPS`. DXVK's HUD doesn't render on MoltenVK.

## Building the patched Wine

```bash
bash build-patched-wine.sh                      # build the 3 modules from Wine 11.16 source + patches/
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

- **Floating schematic panels:** closing the SCH List panel raised a *Control "View…" has no parent window* error during screenshot capture. Dismissing the error restored the schematic. Floating-panel handling needs more testing.
- **Geometry shaders:** MoltenVK has none, so DXVK can't compile Altium pipelines that use them ("Failed to compile pipeline" with a `gs` stage), and those draws are skipped. No missing graphics have been noticed so far.
- **Home Page:** blank, see WebView2 above.
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
