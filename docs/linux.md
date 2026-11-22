# Altium Designer on Linux

The Linux kit uses a dedicated Wine prefix and an application launcher. It
was tested on Ubuntu 24.04 (X11) with Altium Designer 26.12.2.

## Install

Download the release installer and pass your Altium online setup executable,
offline ZIP, or extracted setup folder.

```sh
curl -fsSL https://github.com/lazy-jubei/altium-wine/releases/latest/download/install.sh -o install.sh
bash install.sh --altium-installer "$HOME/Downloads/AltiumDesignerSetup_26_12_2.exe"
```

The release installer verifies the kit archive and stores it under
`~/AltiumWineLinux/kits/<version>`. Run the terminal commands below from
that kit directory or a repository checkout.

Setup downloads and verifies a pinned x86-64 Wine Staging WoW64 build from
[Kron4ek's Wine builds](https://github.com/Kron4ek/Wine-Builds).
Wine, extracted ZIPs, the prefix, and logs live under `~/AltiumWineLinux`.
Use `--root DIR` to select a separate install. Set `ALTIUM_WINE_BIN` to another
Wine executable when testing runners in separate roots.

The installer opens in a regular window. The Linux launcher hides the
decorative effects that can cover modal dialogs under GNOME on X11.
Set `ALTIUM_WINE_INSTALL_DESKTOP=1280x800` to use a Wine virtual desktop.

For online setup, leave **Unified Sign In** enabled and continue in your
browser when Altium asks you to sign in. For offline setup, turn it off
under **Advanced Settings** if it is enabled.
At the end, clear **Run Altium Designer** and click **Finish** so the kit
can apply its graphics settings on first launch.

Use **Altium Designer (Wine)** from the application menu, or use the launcher
from a terminal. The menu shortcut uses the icon from the installed Altium
executable when available.

```sh
bash altium-wine.sh run
bash altium-wine.sh doctor
```

## Altium 365

In Designer, open **License Management**, click **Sign In to Altium Account**,
then click **Sign In** in the dialog. The launcher directs this Altium
authorization request to Wine's host browser bridge. Designer uses the
browser session to sign in. Select an available license and connect to the
workspace from the workspace menu.

For workspace Git cloning, build the patched Wine modules with Git, GCC,
make, bison, flex, and m4 on `PATH`. The kit supplies a MinGW compiler if needed.

```sh
bash build-patched-wine.sh
```

Restart Designer to load them. The shared WinHTTP patch lets Altium's Git
client wait for the server to start sending a large project. The same build
includes the shared Direct2D and DirectWrite redraw and text fixes. For a new
install, `install.sh --build-from-source` builds the modules during setup.

## Rendering

WineD3D with OpenGL is the default. The launcher enables WPF software
rendering for dialogs. The pinned Wine build uses the shared
`InheritWindowMonitor` export stub to keep menus and popups working.

If the Home Page overlaps the editor, clear **Open Home page on start** in
**Preferences → System → General**. The optional `AD26_CEF_FALLBACK=1`
setting seeds the CefSharp preference when the profile has no browser setting.
Its software rendering flags apply to the embedded browser while CAD uses
the selected Direct3D renderer.

Altium's translucent Board Insight Heads Up Display can retain pixels from
the previous PCB view. The Linux launcher defaults it to off when the build
profile has no saved HUD preference. For an existing profile, clear
**Display Heads Up Information** under **Preferences → PCB Editor → Board Insight Modes**
if the overlay is visible. This is a display preference.

If a desktop compositor still interferes with editor windows, use a Wine
virtual desktop for the editor as well. You can also test WineD3D over Vulkan.

```sh
ALTIUM_WINE_DESKTOP=1280x800 bash altium-wine.sh run
ALTIUM_WINE_RENDERER=wined3d-vulkan bash altium-wine.sh run
```

On a hybrid NVIDIA system with PRIME render offload support, use
`ALTIUM_WINE_NVIDIA=1 bash altium-wine.sh run`. Run the `launcher` command with
the same setting to keep it for application-menu launches.

Stock DXVK 3.1.1 uploads partial GDI redraws from the wrong source row.
The Linux build uses the kit's existing GDI patch on upstream DXVK.
Add Meson, Ninja, glslangValidator, and an x86-64 MinGW compiler to `PATH`.

```sh
bash tools/build-linux-dxvk.sh
ALTIUM_WINE_RENDERER=dxvk bash altium-wine.sh run
```

On Intel Iris Xe with Mesa 25.2.8, WineD3D OpenGL sometimes omitted an exposed
copper perimeter in the 3D view. Patched DXVK rendered the perimeter on the
same managed PCB with its original 2D polygon visibility. It remained visible
after switching between 2D, 3D, and the schematic. For application-menu
launches, set the renderer when regenerating the launcher.

```sh
ALTIUM_WINE_RENDERER=dxvk bash altium-wine.sh launcher
```

The probe in `diagnostics/d3d11-gdi-rect.c` passed full and partial uploads
with WineD3D OpenGL, WineD3D Vulkan, and patched DXVK. The installer modal can
be checked by opening **Advanced** on the license agreement page, checking
that the dialog text and buttons are visible, and clicking **OK**.

### Measure schematic redraw

On X11, open a populated region of a schematic and zoom in until you can
scroll several notches in either direction. Choose a capture rectangle
inside the drawing area and keep the zoom and window size the same for each
run. The script sends wheel events at the center of the rectangle and counts
visible frames that change. A sheet boundary can suppress redraws while
wheel input continues.

```sh
/usr/bin/python3 diagnostics/linux-schematic-fps.py 420 195 1260 760 --seconds 9 --wheel-burst 4
```

Adjust the coordinates to fit your window. `--wheel-burst` sets the number
of notches per direction. Add `--pan` to measure right-drag panning. The
script needs Python GObject, GTK 3, and libXtst.

On Ubuntu 24.04 with Intel Iris Xe, WineD3D OpenGL and a 1920×1152
Designer window, three 9-second runs on the same schematic at editing
zoom measured 12.9–14.3 visible redraws per second with stock Direct2D
and DirectWrite and 51.3–59.4 with the shared patches. The first 18-second
trial after a fresh launch with the patches measured 43.4. The
`d2d-primitive-check.cpp` probe matched all 4,194,304 output bytes for
both Direct2D factory types after toggling batching, the primitive cache,
and lazy state together.

With patched DXVK and the PCB open in the same session, three 9-second
schematic wheel trials measured 42.2–45.2 visible redraws per second.
