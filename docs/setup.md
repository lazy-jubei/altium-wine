# Setup guide

## Installation location

Nothing is installed system-wide. Wine, the prefix and the downloads all live in `~/AltiumWine`, so deleting that folder undoes everything (or use `install.sh --uninstall`). The exceptions:

- Rosetta 2 if it's missing (asked first).
- If Homebrew is present, `cabextract` for the fonts and `bison` when building Wine (installed without asking).
- The launcher app in `~/Applications`.

## Install

Download the [v1.0.0 installer](https://github.com/lazy-jubei/altium-wine/releases/tag/v1.0.0), inspect it, then run it:

```bash
curl -fL https://github.com/lazy-jubei/altium-wine/releases/download/v1.0.0/install.sh -o install.sh
bash install.sh
```

For a specific offline setup folder or ZIP, use `bash install.sh --altium-installer /path/to/offline-setup`. The release includes prebuilt patched Wine modules, so Xcode and Homebrew are not required for the default install.

The installer sets up Wine and fonts, runs your Altium installer, and creates `~/Applications/Altium Designer (Wine).app`. Downloads are checksum-verified. Get the Altium offline installer from your Altium account.

- `--altium-installer PATH`
- `--skip-altium`
- `--reinstall-altium`
- `--build-from-source`
- `--root DIR`
- `--no-launcher`
- `--yes`
- `--uninstall`

Re-running `install.sh` updates the kit and patched Wine and keeps Altium and your projects.

From the repository root, which compiles the patched Wine locally:

```bash
bash install.sh                # or step by step:
bash altium-wine.sh            # setup + fonts + patched Wine + the Altium installer
bash altium-wine.sh run        # start Altium
bash altium-wine.sh launcher   # create the launcher app
```

The launcher app can't read a kit inside `~/Downloads`, `~/Desktop` or `~/Documents`: macOS blocks it without prompting. For such a kit, `launcher` copies the kit to `~/AltiumWine/kit` and runs that copy. Run `launcher` again after changing the kit.

The first run:

1. Downloads the WineHQ macOS build (Gcenx wine-staging 11.16, about 185 MB, checksum-verified).
2. Builds the patched Wine (`build-patched-wine.sh`, about 15 min the first time). It needs the Xcode Command Line Tools and Homebrew, unless `PATCHED_MODULES_DIR` points at prebuilt modules.
3. Creates the prefix, installs core fonts and starts `Installer.Exe`.

DXVK-macOS (about 4 MB, checksum-verified) is downloaded the first time you `run`.

**While the installer is open:**

- On the License Agreement page, click **Advanced Settings** and untick **Unified Sign In**. Use the login form inside the installer.
- If the window goes blurry and stops responding, a dialog is hidden behind it. Bring it forward with Mission Control (F3) or the **Window** menu.

**First start of Altium:**

- **Sign-in:** Altium opens your Mac's browser. After the browser says "You have successfully authenticated", restart Altium (File › Exit, then `run` again). The session only shows up after a restart.
- **Local network prompt:** macOS asks the app that launched Wine for "local network" access because Altium searches for license servers. Allow it only if you use an on-premise Altium server.
- **Home Page:** turn it off in Preferences › System › General. It's a WebView2 page that stays blank under Wine.

