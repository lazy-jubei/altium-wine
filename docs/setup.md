# Setup guide

## Installation location

Nothing is installed system-wide. Wine, the prefix and the downloads all live in `~/AltiumWine`, so deleting that folder undoes everything (or use `install.sh --uninstall`). The exceptions:

- On Apple Silicon, Rosetta 2 if it's missing (asked first).
- MacPorts, if it isn't installed, then `cabextract` for the fonts and `bison` when building Wine. Installing them needs an administrator password (or passwordless sudo).
- The launcher app in `~/Applications`.

## Install

Download the installer from the [latest release](https://github.com/lazy-jubei/altium-wine/releases/latest), inspect it, then run it:

```bash
curl -fL https://github.com/lazy-jubei/altium-wine/releases/latest/download/install.sh -o install.sh
bash install.sh
```

Pass an online setup .exe, offline setup folder, or offline ZIP with `--altium-installer`.
The release includes prebuilt patched Wine modules, so Xcode is not required for the default install.

A setup window walks you through it (`--terminal` asks in Terminal instead). The installer sets up Wine and fonts, runs your Altium installer, and creates `~/Applications/Altium Designer (Wine).app`. Downloads are checksum-verified. Get the Altium installer from your Altium account.

- `--altium-installer PATH`
- `--skip-altium`
- `--reinstall-altium`
- `--build-from-source`
- `--root DIR`
- `--no-launcher`
- `--yes`
- `--uninstall`

Re-run `install.sh` and choose **Update** to keep Altium, its settings, and your projects.
**Clean Install** erases the existing Wine container, including any projects stored inside it.
Setup closes Altium in that container first and waits for you to answer any save prompts.

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
2. Builds the patched Wine (`build-patched-wine.sh`, about 15 min the first time). It needs the Xcode Command Line Tools and MacPorts (for bison), unless `PATCHED_MODULES_DIR` points at prebuilt modules.
3. Creates the prefix, installs Microsoft core fonts, Aptos, and the PowerPoint Viewer fonts including Consolas, then starts the chosen installer. Winetricks downloads these for local use in the Wine prefix. Re-running setup installs newly added fonts in existing prefixes.

DXVK-macOS (about 4 MB, checksum-verified) is downloaded the first time you `run`.

**While the installer is open:**

- For online setup, leave **Unified Sign In** enabled and sign in through the Mac's default browser.
- For offline setup, open **Advanced Settings** on the License Agreement page and untick **Unified Sign In**. Use the login form inside the installer.
- If the window goes blurry and stops responding, a dialog is hidden behind it. Bring it forward with Mission Control (F3) or the **Window** menu.

**First start of Altium:**

- **Sign-in:** Altium opens your Mac's browser. After the browser says "You have successfully authenticated", restart Altium (File › Exit, then `run` again). The session only shows up after a restart.
- **Local network prompt:** macOS asks the app that launched Wine for "local network" access because Altium searches for license servers. Allow it only if you use an on-premise Altium server.
- **Home Page:** turn it off in Preferences › System › General. It's a WebView2 page that stays blank under Wine.

