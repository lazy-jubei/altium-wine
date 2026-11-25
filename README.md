# Altium Designer on macOS and Linux with Wine

[![Quality Gate](https://sonarcloud.io/api/project_badges/measure?project=lazy-jubei_altium-wine&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=lazy-jubei_altium-wine)

Run Altium Designer on macOS and x86-64 Linux with patched Wine. From a checkout,
`install.sh`, `altium-wine.sh`, and `build-patched-wine.sh` automatically select
the implementation for your operating system.

Tested with Altium Designer 26.12.2 on Ubuntu 24.04 (X11), with 17.1 and
26.10.1 on an M4 Mac running macOS 15.7.9, and with 26.11.1 on an Intel Mac
running macOS 15.8.2. Altium 365 project cloning works with the patched Wine
build.

![3D PCB rotation in Altium on macOS](docs/screenshots/limesdr-pcb-rotation.gif)

*[LimeSDR-USB](docs/screenshots/README.md) by [Lime Microsystems / Myriad-RF](https://github.com/myriadrf/LimeSDR-USB).*

## Install

Get the online setup executable, offline ZIP, or extracted offline setup folder
from your Altium account. Run the same command on macOS or Linux to download and
open the setup window.

```bash
curl -fsSL https://github.com/lazy-jubei/altium-wine/releases/latest/download/install.sh -o install.sh && bash install.sh
```

The installer detects the operating system and opens a graphical setup window
by default in a desktop session. Use `bash install.sh --terminal` for
command-line setup.

### Linux

The installer installs GTK4 and PyGObject as needed on supported distributions.
Open **Altium Designer (Wine)** from your application menu when setup finishes.
For an existing installation, rerun the command above and choose **Update**.
The installed kit also supports `altium-wine.sh update` and
`altium-wine.sh update --check`. [Linux setup guide](docs/linux.md)

### macOS

The setup window is built on your Mac with Apple’s Command Line Tools. The
installer uses Terminal if those tools are unavailable. Online setup opens
your Mac’s default browser with **Unified Sign In** enabled.

![The Altium Designer setup window](docs/screenshots/setup-window.png)

The installer sets up Wine and fonts and creates `~/Applications/Altium Designer (Wine).app`. It uses prebuilt Wine modules, so Xcode isn't required. The fonts need `cabextract`, which comes from MacPorts; setup installs MacPorts from its notarized package if it isn't there (one administrator password). On Apple Silicon, Rosetta 2 is required; setup offers to install it.

On a Retina display Altium draws at 2× for sharp text. On a standard (1×) display it draws at 1× and a Direct2D patch antialiases the schematic text instead; the display is checked each time Altium starts (`RETINA_MODE` in `config.sh` overrides it).

Altium's Windows drive lives in its own case-insensitive disk image, `~/AltiumWine/altium-wine.sparsebundle` (mounted at `~/AltiumWine/volume`), so it works the same on any Mac drive. The image only takes the space it uses, up to 200 GB. An install from before the image keeps its prefix in `~/AltiumWine/prefix`.

Optimizations include:

- Cached Direct2D geometry and ordered AD26 draw batching for faster schematics.
- Matched color spaces, parallel copies and native AD17 pan compositing.
- Queued Direct3D uploads, [AD17 PCB helpers and optional Metal grid caching](docs/technical-notes.md#altium-17).
- Fixes for hidden dialogs, floating panels, tooltip input and Vault freezes.
- macOS app-control support and WebView2 cleanup that waits for an idle editor.
- AD26 uses its bundled CefSharp browser for the Home Page by default to avoid WebView2 errors under Wine.
- Multi-monitor fixes: windows drag onto any display, and menus and dialogs open on the display Altium is on.

For faster AD17 3D panning, disable **Use Ordered Blending in 3D** in **Preferences → PCB Editor → Display**. [Tuning details](docs/technical-notes.md).

Wine and Altium live in `~/AltiumWine`. Re-run `install.sh` and choose **Update**.

[Setup and sign-in guide](docs/setup.md) · [Patch details and troubleshooting](docs/technical-notes.md)

## Optional Metal renderer for Altium 26

On an Intel Mac, the release installs a DXMT renderer alongside the default DXVK
runtime. Set `AD26_RENDERER=dxmt` in the kit's `config.local.sh` and restart Altium to
try it. Set `AD26_RENDERER=dxvk` to switch back.

The DXMT path restores exposed copper in 3D and supports the 2D PCB grid and
schematic rendering. It was tested on Altium 26.12.2 with an AMD Radeon RX 6900 XT
on macOS 15.8.2. The renderer is experimental.

## Screenshots

**PCB View**

![PCB View](docs/screenshots/limesdr-pcb-2d.png)

**Schematic view**

![Schematic pan](docs/screenshots/limesdr-schematic-pan.gif)

**Altium 17**

![Altium 17 schematic view](docs/screenshots/altium17-schematic.png)

## Build on macOS

Requires Xcode Command Line Tools, MacPorts and, on Apple Silicon, Rosetta 2 (installed for you if missing). Allow about 3 GB of disk space and 15 minutes for the first build.

```bash
git clone https://github.com/lazy-jubei/altium-wine.git
cd altium-wine
bash install.sh --build-from-source --altium-installer /path/to/offline-setup
```

The build patches Wine 11.16 for rendering, Rosetta, dialogs, networking and AD17 startup. Output: `~/AltiumWine/wine-patched`.

To rebuild and export the modules with checksums:

```bash
bash build-patched-wine.sh --export ~/AltiumWine/build/modules-export
```
