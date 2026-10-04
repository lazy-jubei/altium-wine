# Wine sources for the release

The v1.0.0 release distributes five replacement Wine modules, together with
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
`d2d1.dll` and `winhttp.dll` from Wine 11.16 source. `winemac.so` also includes
Wine Staging's no-flicker patch, which is retained in `patches/0000`.
`wow64cpu.dll` and `user32.dll` are transformed from the checksum-pinned stock
bundle by the two Python patchers in `patches/`. No other stock modules are
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
